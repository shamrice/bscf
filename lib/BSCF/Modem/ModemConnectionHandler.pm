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
    MODEM_HANGUP => 'ATH',
};

no warnings qw(experimental::try);

$Data::Dumper::Sortkeys = 1;


sub new {
    my ($class, %args) = @_;

    my $config = BSCF::Configuration::Config->new(package => $class);
    my $log = BSCF::Log::Logger->new(name => $class);
    my $lock_file = $args{conn_lock_file} || './conn.log';

    my $self = {
        config => $config,
        log => $log,
        conn_lock_file => $lock_file,
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

sub run {
    my ($self) = @_;

    my $com_port = $self->_config->get('modem_com_port', '/dev/ttyACM0');
    my $baud_rate = $self->_config->get('modem_baud_rate', 300);
    my $data_bits = $self->_config->get('modem_databits', 8);
    my $parity = $self->_config->get('modem_parity', 'none');
    my $stop_bits = $self->_config->get('modem_stop_bits', 0);
    my $handshake = $self->_config->get('modem_handshake', 'none');

    my $modem_init = $self->_config->get('modem_init', 'ATZ');

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
            $modem->baudrate($baud_rate);
            $modem->databits($data_bits);
            $modem->parity($parity);
            $modem->stopbits($stop_bits);
            $modem->handshake($handshake);
            $modem->error_msg(1);
            $modem->user_msg(1);
            $modem->read_const_time(5000); # 5 second pause waiting for streamline($count) input

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
                    $self->_log->info("Answering incoming phone call...");
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
                    }
                } else {
                    $self->_log->info("Didn't receive ring. RECV=|$recv|");
                   # sleep 10;
                }
            }

            my $server_socket = IO::Socket::INET->new(PeerAddr => $self->_config->get('destination_bbs_host', 'localhost'),
                                                PeerPort => $self->_config->get('destination_bbs_port', 9223),
                                                Proto    => $self->_config->get('destination_bbs_proto', 'tcp'),
                                                Timeout  => 1);
                die "Connect failed!" unless $server_socket;

            $server_socket->setsockopt(
                SOL_SOCKET, SO_RCVTIMEO,
                pack('l!l!', 1, 0)
            ) or confess "Failed to set recv timout: $!";

            $server_socket->blocking(0);
            $self->_log->info("Successfully connected to remote BBS server!");

            my $server_input = '';
            my $client_input = '';
            my $bytes_read = 0;

            #$modem->read_const_time(0); # set input back to non-blocking

            while ($is_conn && $server_socket->connected) {

                $server_input = '';

                # issue with below is that it only sends about 4 full lines of text regardless
                # on how it's chopped up.. need to figure out wtf is going on there. Maybe need to
                # wait for some modem register to clear?

                do {
                    $bytes_read = $server_socket->sysread($server_input, 4096);
                    #$bytes_read = $server_socket->recv($server_input, 40);

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

                # TODO : it shouldn't allow user input until above is actually sent.
                # noticed that this isn't the case.

                $client_input = $modem->input;

                if ($client_input ne '') {
                    $server_socket->send($client_input);
                    #$last_send = time;
                    #timeout_warning_sent = 0;
                }


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
