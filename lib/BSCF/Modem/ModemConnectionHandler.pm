package BSCF::Modem::ModemConnectionHandler;

use v5.34;
use feature qw(try);

use Carp;
use Data::Dumper;
use Device::SerialPort qw( :STAT );
use IO::Socket::INET;
use Time::HiRes qw(usleep);

use constant {
    MODEM_OK => 'OK',
    MODEM_RING => 'RING',
    MODEM_ANSWER => 'ATA',
    MODEM_CONNECT => 'CONNECT',
    MODEM_RESET => 'ATZ',
    MODEM_HANGUP => 'ATH',

    REMOTE_CONNECT_CHECK_CMD => 'nc -zv _IP_ _PORT_ 2>&1',
};

no warnings qw(experimental::try);

$Data::Dumper::Sortkeys = 1;


sub new {
    my ($class, %args) = @_;

    my $config = BSCF::Configuration::Config->new(package => $class);
    my $log = BSCF::Log::Logger->new(name => $class);
    my $lock_file = $args{conn_lock_file} || './conn.log';

    my $destination_bbses = $config->get('destination_bbs_map', '');
    my @dest_bbs_entries = split(',', $destination_bbses);

    my $dialup_mode_connect_bytes_config = $config->get('destination_bbs_force_dialup_mode_connect_bytes', '');
    my $dialup_connect_bytes = '';
    foreach my $byte (split(',', $dialup_mode_connect_bytes_config)) {
        $dialup_connect_bytes .= pack('C', $byte);
    }


    my $self = {
        config => $config,
        log => $log,
        conn_lock_file => $lock_file,
        dest_bbs_entries => \@dest_bbs_entries,
        dest_bbs_force_dialup_connect_bytes => $dialup_connect_bytes
    };

    return bless($self, $class);
}


sub _config {
    return shift->{config};
}

sub _log {
    return shift->{log};
}

sub _conn_lock_file {
    return shift->{conn_lock_file};
}

sub _dest_bbses {
    my ($self) = @_;
    return $self->{dest_bbs_entries} // [ ];
}


sub _dest_bbs_force_dialup_connect_bytes {
    return shift->{dest_bbs_force_dialup_connect_bytes} // '';
}


sub _get_online_bbses {
    my ($self) = @_;

    my %online_bbses;
    my $idx = 0;

    foreach my $dest_bbs ($self->_dest_bbses->@*) {
        my ($name, $connect_info) = split('\|', $dest_bbs);

        $name ||= '';
        if (!$connect_info) {
            $self->_log->error("Missing connection info in dest bbs entry: $dest_bbs :: skipping.");
            next;
        }
        my ($ip, $port) = split(':', $connect_info);
        $port ||= 23;

        my $conn_check_cmd = REMOTE_CONNECT_CHECK_CMD;
        $conn_check_cmd =~ s/\_IP\_/$ip/;
        $conn_check_cmd =~ s/\_PORT\_/$port/;

        my @conn_check = qx{ $conn_check_cmd };
        if (!grep(/succeeded/gmi, @conn_check)) {
            $self->_log->warn("Destination BBS: $name ($connect_info) is offline. :: " . join('', @conn_check));
            next;
        }

        $self->_log->info("Destination BBS: $name ($connect_info) is online.");
        $online_bbses{$idx} = {
            name => $name,
            ip => $ip,
            port => $port,
        };
        $idx++;
    }

    return \%online_bbses;
}


sub _connect_to_remote_bbs {
    my ($self, $ip, $port) = @_;

    confess "Cannot connect to remote bbs, no IP was given!" if (!$ip);
    $port ||= 23;

    my $server_socket = IO::Socket::INET->new(  PeerAddr => $ip,
                                                PeerPort => $port,
                                                Proto    => 'tcp',
                                                Timeout  => 1);

    if (!$server_socket) {
        $self->_log->warn("Remote BBS at $ip:$port is offline.");
        return;
    }

    $server_socket->setsockopt(
        SOL_SOCKET, SO_RCVTIMEO,
        pack('l!l!', 1, 0)
    ) or confess "Failed to set recv timout: $!";

    $server_socket->blocking(0);
    $self->_log->info("Successfully connected to remote BBS server: $ip:$port");

    if ($self->_dest_bbs_force_dialup_connect_bytes) {
        $self->_log->info("Sending configured byte string to remote BBS to signal a dial up connection...");
        $server_socket->send($self->_dest_bbs_force_dialup_connect_bytes);
    }

    return $server_socket;
}




sub _get_user_dest_bbs_selection {
    my ($self, $modem_dev, $online_bbses) = @_;

    die "Missing modem device or list of online bbses to select from. Cannot select BBS to connect to!" if (!$modem_dev || !$online_bbses);


    $modem_dev->write("\r\n" . chr(155));
    $modem_dev->write("Please select a BBS: \r\n" . chr(155));
    $modem_dev->write("--------------------- \r\n" . chr(155));

    foreach my $idx (sort { $a <=> $b } keys $online_bbses->%*) {
        $modem_dev->write(" " . ($idx + 1) . ") " . $online_bbses->{$idx}{name} . " \r\n" . chr(155));
    }
    $modem_dev->write(" G) ood Bye \r\n" . chr(155));
    $modem_dev->write("\r\n" . chr(155));
    $modem_dev->write("Choice? ");
    $self->_log->warn("Failed to wait for data to write") if (!$modem_dev->write_drain);

    my $dest_socket;
    my $attempts = 0;
    my $is_valid = 0;
    my $atascii_newline = chr(155);
    while (!$is_valid && $attempts < 5) {
        my $recv = '';

        $recv = $modem_dev->input while (!$recv);
        $modem_dev->write($recv);

        $recv =~ s/\r|\n|$atascii_newline//gm;

        $self->_log->info("ATTEMPT: $attempts :: CHOICE ENTRY=$recv");
        if ($recv =~ m/^\d+$/) {
            $recv--;
            if (exists $online_bbses->{$recv}) {
                $dest_socket = $self->_connect_to_remote_bbs($online_bbses->{$recv}{ip}, $online_bbses->{$recv}{port});
                $is_valid = 1;
            }
        } elsif ($recv =~ m/G/i) {
            $modem_dev->write("\r\n" . chr(155) . "Good bye!\r\n" . chr(155));
            $self->_log->warn("Failed to wait for data to write") if (!$modem_dev->write_drain);
            sleep 1;
            return;
        } else {
            $modem_dev->write("\r\n" . chr(155) . "Invalid selection! " . "\r\n" . chr(155));
            sleep 1;
            $modem_dev->write("Choice? ");
            $self->_log->warn("Failed to wait for data to write") if (!$modem_dev->write_drain);
            $attempts++;
        }
    }

    $modem_dev->write("\r\n" . chr(155));

    return $dest_socket;
}



sub run {
    my ($self) = @_;

    my $com_port = $self->_config->get('modem_com_port', '/dev/ttyACM0');
    my $baud_rate = $self->_config->get('modem_baud_rate', 300);
    my $data_bits = $self->_config->get('modem_databits', 8);
    my $parity = $self->_config->get('modem_parity', 'none');
    my $stop_bits = $self->_config->get('modem_stop_bits', 0);
    my $handshake = $self->_config->get('modem_handshake', 'none');

    my $modem_init = $self->_config->get('modem_init', MODEM_RESET);

    my $sleep_dur_on_failure = $self->_config->get('sleep_duration_on_failure', 60);
    my $sleep_dur_on_connect = $self->_config->get('sleep_duration_on_connect', 10);

    my $modem_ok = MODEM_OK;
    my $modem_ring = MODEM_RING;
    my $modem_connect = MODEM_CONNECT;

    $self->_log->info("Running modem connection handler with config :: com port: $com_port :: baud rate: $baud_rate :: databits: $data_bits :: parity: $parity :: stop bits: $stop_bits :: handshake :: $handshake");

    while(1) {
        my $is_conn = 0;
        my $is_modem_open = 0;
        my $modem;
        try {

            $modem = Device::SerialPort->new($com_port);
            confess "Failed to init modem on com port: $com_port :: $!" if (!$modem);
            $modem->baudrate($baud_rate);
            $modem->databits($data_bits);
            $modem->parity($parity);
            $modem->stopbits($stop_bits);
            $modem->handshake($handshake);
            $modem->error_msg(1);
            $modem->user_msg(1);
            $modem->read_const_time(5000); # 5 second pause waiting for streamline($count) input

            $modem->purge_all;

            $self->_log->info("Initializing modem for next connection with: $modem_init");
            $modem->write("$modem_init\r");
            $self->_log->warn("Failed to wait for data to write") if (!$modem->write_drain);

            #sleep 5;

            my ($count, $recv) = $modem->read(255);
            if (!$count || $recv !~ m/$modem_ok/) {
                $self->_log->fatal("Failed to get an OK response from modem init! Received: |$recv| :: Sleeping $sleep_dur_on_failure seconds and trying again...");
                sleep $sleep_dur_on_failure;
                next;
            }

            $self->_log->info("Waiting for incoming phone call...");

            while (!$is_conn) {
                #my $recv = $modem->input;

                # TODO : need to figure out blocking without having to specify count.. otherwise can read stuff like
                #        ING instead of RING
                my $recv = $modem->streamline(5);
                if ($recv =~ m/$modem_ring/) {
                    $self->_log->info("Answering incoming phone call :: |$recv|");
                    sleep 1;
                    $self->_log->info("Sending pickup: " . MODEM_ANSWER);
                    $modem->write(MODEM_ANSWER . "\r");
                    $self->_log->warn("Failed to wait for data to write") if (!$modem->write_drain);
                    sleep $sleep_dur_on_connect;

                    ($count, $recv) = $modem->read(255);
                    if ($count && $recv =~ m/$modem_connect/) {
                        $self->_log->info("Call connected! |$recv|");
                        $is_conn = 1;
                    } else {
                        $self->_log->warn("Failed to connect to incoming phone call. :: Sleeping $sleep_dur_on_failure seconds :: Received: |$recv|");
                        $modem->write(MODEM_HANGUP . "\r");
                        $self->_log->warn("Failed to wait for data to write") if (!$modem->write_drain);
                        sleep $sleep_dur_on_failure;
                        $modem->purge_all;
                    }
                } else {
                   # $self->_log->info("Didn't receive ring. RECV=|$recv|");
                }
            }

            my $online_bbses = $self->_get_online_bbses;
            my $num_online_bbses = scalar (keys $online_bbses->%*);

            my $server_socket;
            if (!$num_online_bbses) {
                $modem->write("\r\n" . chr(155) . "Sorry, BBS is currently offline!\r\n" . chr(155) . "Please try again later.\r\n" . chr(155));
                $self->_log->warn("Failed to wait for data to write") if (!$modem->write_drain);
                sleep 10;

                confess "No online BBSes to connect to!";
            } elsif ($num_online_bbses == 1) {
                $server_socket = $self->_connect_to_remote_bbs($online_bbses->{0}{ip}, $online_bbses->{0}{port});
            } else {
                $self->_log->info("CURRENTLY $num_online_bbses ARE ONLINE");
                $server_socket = $self->_get_user_dest_bbs_selection($modem, $online_bbses);
                # TODO : Display list to choose from.
            }

            if (!$server_socket) {
                confess "No destination BBS selected to connect to. Disconnecting user...";
            }

            my $server_input = '';
            my $client_input = '';
            my $bytes_read = 0;

            while ($is_conn && $server_socket->connected) {

                $server_input = '';
                $client_input = '';

                do {
                    $bytes_read = $server_socket->sysread($server_input, 4096);

                    if ($bytes_read) {
                        $self->_log->info("BYTES READ: $bytes_read :: |$server_input|");

                        my @bytes = split('', $server_input);

                        foreach my $byte (@bytes) {
                            my $count_out = $modem->write($byte);
                            if (!$count_out) {
                                $self->_log->error("Write failed! byte: $byte");
                            } elsif ($count_out != length $byte) {
                                $self->_log->error("Write failed. Partial transmission of |$byte| :: sent: $count_out");
                            }
                            $self->_log->warn("Failed to wait for data to write") if (!$modem->write_drain);
                        }


                    } elsif (defined $bytes_read && $bytes_read == 0) {
                        $self->_log->fatal("Server disconnected! Closing server socket.");
                        $server_socket->close();
                        $is_conn = 0;
                        last;
                    }
                } until (!$bytes_read);


                # TODO : need to make this blocking until user has input without a busy loop
                $client_input = $modem->input;
                $server_socket->send($client_input) if ($client_input);

                # check if connection dropped.. if so, hang up.
                if ($modem->can_modemlines) {
                    my $status = $modem->modemlines;
                    if (!($status & $modem->MS_RLSD_ON)) {
                        $self->_log->fatal("NO CARRIER : Dropping phone call. Status=|$status|");
                        $is_conn = 0;
                    }
                }
            }

            $modem->write(MODEM_HANGUP . "\r");
            $self->_log->warn("Failed to wait for data to write") if (!$modem->write_drain);
            sleep $sleep_dur_on_connect;

        } catch ($conn_error) {
            $self->_log->fatal("Error during modem connection: $conn_error");
            if ($modem && $is_modem_open) {
                $modem->write(MODEM_HANGUP . "\r");
                $self->_log->warn("Failed to wait for data to write") if (!$modem->write_drain);
            }
        }

        if ($modem) {
            $modem->purge_all;
            $modem->close || do {
                $self->_log->error("Failed to close modem: $!");
            }
        }

        $self->_log->warn("Modem connection closed. Resetting for next connection...");
        sleep $sleep_dur_on_connect;
    }


    return;
}

1;
