package BBSSingleConnectionFilter;

use v5.34;
use feature qw(try);

use threads ('exit' => 'threads_only');
use threads::shared;

use Carp;
use DateTime;
use Data::Dumper;

use FindBin qw($Bin);
use lib("$Bin/../lib");

use IO::Socket::INET;
use POSIX qw(strftime);
use Thread::Queue;

use BSCF::Configuration::Config;
use BSCF::Log::Logger;
use BSCF::Log::LogQueue;

use constant {
    ATASCII_CURSOR_UP_CODE => 28,
    ATASCII_RETURN_KEY_CODE => 155,
    ATASCII_INSERT_LINE_CODE => 157,
    ANSI_RETURN_KEY_CODE => 13,
    ASCII_ESC_KEY_CODE => 27,
};

no warnings qw(experimental::try);

our $VERSION = '0.1';
our $BOOT_DATE = DateTime->now;

my $is_running :shared;
my $disconnect_call_log_queue = Thread::Queue->new;



sub new {
    my ($class, %args) = shift;

    my $config_file = $args{config};
    my $config = BSCF::Configuration::Config->new(package => __PACKAGE__);

    my $server_socket = IO::Socket::INET->new(
       # LocalHost => $config->get('server_host'),
        LocalPort => $ENV{PORT} // $config->get('server_port'),
        Proto => $config->get('server_proto'),
        Listen => $config->get('server_listen'), # SOMAXCONN,
        Timeout => $config->get('server_timeout'),
        ReuseAddr => $config->get('server_reuse_address'),
        Type => SOCK_STREAM,
    );

    confess "Failed to set server socket: $!" if (!$server_socket);

    # sets timeout for input on recv calls. (l!l! = type long long.. hacky and not very portable.)
    # needed for 'RAW' connections instead of TELNET as they don't listen to server_timeout set above.
    $server_socket->setsockopt(
        SOL_SOCKET, SO_RCVTIMEO,
        pack('l!l!', $config->get('server_input_timeout', 10), 0)
    ) or confess "Failed to set recv timout: $!";

    my $log = BSCF::Log::Logger->new(name => $class);

    my @blocked_ip_prefixes = split(/,/, $config->get('ip_block_list', ''));
    my @allowed_ip_prefixes = split(/,/, $config->get('ip_allow_list', ''));

    my $conn_lock_file = $config->get('connection_lock_file', '../conn.lock');

    my $self = {
        allowed_ip_prefixes => \@allowed_ip_prefixes,
        blocked_ip_prefixes => \@blocked_ip_prefixes,
        config => $config,
        log => $log,
        server_socket => $server_socket,
        conn_lock_file => $conn_lock_file,
        last_connect => 0,
    };

    $is_running = 0;

    return bless($self, $class);
}

sub _allowed_ip_prefixes {
    return shift->{allowed_ip_prefixes};
}

sub _blocked_ip_prefixes {
    return shift->{blocked_ip_prefixes};
}


sub _config {
    return shift->{config};
}

sub _log {
    return shift->{log};
}

sub _server_socket {
    return shift->{server_socket} // die "Communication socket not set!";
}

sub _last_connect {
    my ($self, $new_val) = @_;

    if (defined $new_val && $new_val > 0) {
        $self->_log->warn("Setting last connect to: " . $new_val);
        $self->{last_connect} = $new_val;
    }

    return $self->{last_connect} // 0;
}

sub _conn_lock_file {
    return shift->{conn_lock_file};
}

sub run {
    my ($self) = @_;
    $self->_log->info("BSCF starting...");

    $is_running = 1;

    my $cleanup_thread = threads->new(sub { $self->_thread_clean_up; });

    my $log_queue_thread = threads->new(sub {
        BSCF::Log::LogQueue::log_queue_handler_thread;
    });


    if (-e $self->_conn_lock_file) {
        $self->_log->warn("Connection lock file exists on start up! Deleting existing file...");
        unlink($self->_conn_lock_file) or do {
            $self->_log->fatal("Failed to delete lock file! :: $!");
            $self->_server_socket->close;
            return;
        };
    }

    $self->_accept_connections;

    $self->_server_socket->close;
    $_->join foreach (threads->list(threads::all));


    $self->_log->fatal("SHUTDOWN COMPLETE");
    return;
}


sub _accept_connections {
    my ($self) = @_;
    $self->_log->warn("BSCF Server v$VERSION is up and waiting for connections!");

    my $num_worker_threads = threads->list(threads::all); # workers are set up before connections so threads will already be running.
    my $max_num_user_threads = $self->_config->get('max_num_user_connections', 5);

    do {
        my $client_socket = $self->_server_socket->accept;
        if ($client_socket && $client_socket->connected) {

            my $client_ip = $client_socket->peerhost;

            if ($self->_is_client_ip_blocked($client_ip)) {
                $self->_log->fatal("Disconnecting blocked user from ip: $client_ip:" . $client_socket->peerport);
                $client_socket->close;

            } else {
                my $cur_num_user_threads = (threads->list(threads::running)) - $num_worker_threads;
                my $allow_connect = 1;
                if ($cur_num_user_threads < $max_num_user_threads) {

                    $self->_log->warn("New connection accepted from $client_ip :: Num worker threads: $num_worker_threads :: Num user threads: " . ($cur_num_user_threads + 1) . " :: Max user threads: $max_num_user_threads");

                    if (-e $self->_conn_lock_file) {
                        if (time - $self->_last_connect > 30) {
                            $self->_log->fatal("Lock file exists but session is expired. Force deleting lock file and allowing new session!");
                            unlink($self->_conn_lock_file) or do {
                                $self->_log->fatal("Failed to delete lock file! :: $!");
                            };
                        } else {
                            $self->_log->warn("BBS connection lock file exists! BBS is currently busy. Disconnecting user...");
                            $self->_send_client_busy_screen($client_socket);
                            sleep 1;
                            $client_socket->close;
                            $allow_connect = 0;
                       }
                    }

                    if ($allow_connect) {
                        $self->_last_connect(time);
                        my $user_handler_thread = threads->new(sub { $self->_handle_user_connection($client_socket); });
                    }

                } else {

                    $self->_log->fatal("Connection blocked due to max connections already open. Num worker threads: $num_worker_threads :: Num user threads: $cur_num_user_threads :: Max user threads: $max_num_user_threads");

                    my $dest_bbs_name = $self->_config->get('destination_bbs_name', 'BBS');

                    $client_socket->send(pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(" $dest_bbs_name " . pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(' ________________________________ ' . pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(' Sorry! Max number of connections ' . pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(' are currently being used. ' . pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(' Please try again later... ');
                    $client_socket->send(pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(pack('C', 155) . (pack('C', 13) . pack('C', 10)));
                    $client_socket->send(' Disconnecting... Bye! ');
                    $client_socket->send(pack('C', 155) . (pack('C', 13) . pack('C', 10)));

                    sleep 1;
                    $client_socket->close;
                }
            }

        } else {
            $self->_log->debug("TIMEOUT :: Client did not connect...");
        }
    } while ($is_running);

    return;
}


=head2 _handle_user_connection
    (New thread) Connects user to BBS and deletes lock file on disconnect
=cut
sub _handle_user_connection {
    my ($self, $client_socket) = @_;

    # Thread 'cancellation' signal handler
    $SIG{'KILL'} = sub { threads->exit(); };

    my $client_ip = $client_socket->peerhost;

    $self->_log->info("Connection from IP: $client_ip:" . $client_socket->peerport);


    $client_socket->timeout(1);
    # sets timeout for input on recv calls. (l!l! = type long long.. hacky and not very portable.
    # needed for 'RAW' connections instead of TELNET as they don't listen to timeout set above.
    $client_socket->setsockopt(
        SOL_SOCKET, SO_RCVTIMEO,
        pack('l!l!', 1, 0)
    ) or confess "Failed to set recv timout: $!";

    my $server_socket;

    try {
        $server_socket = IO::Socket::INET->new(PeerAddr => $self->_config->get('destination_bbs_host', 'localhost'),
                                        PeerPort => $self->_config->get('destination_bbs_port', 9223),
                                        Proto    => $self->_config->get('destination_bbs_proto', 'tcp'),
                                        Timeout  => 1);
        die "Connect failed!" unless $server_socket;
    } catch ($connect_error) {
        $self->_log->error("Can't connect to external BBS! :: $connect_error");
        $self->_send_client_offline_screen($client_socket);
        $client_socket->close;
        return;
    }

    $server_socket->setsockopt(
        SOL_SOCKET, SO_RCVTIMEO,
        pack('l!l!', 1, 0)
    ) or confess "Failed to set recv timout: $!";

    $client_socket->blocking(0);
    $server_socket->blocking(0);
    $self->_log->info("Successfully connected to remote BBS server!");

    $self->_log->info("Creating new connection lock file: " . $self->_conn_lock_file);
    open(my $FH, ">", $self->_conn_lock_file);
    close($FH);

    my $last_send = time;
    my $timeout_warning_sent = 0;

    while ($client_socket->connected && $server_socket->connected) {

        my $server_input = '';

        $server_socket->recv($server_input, 1);

        if ($server_input ne '') {
            $client_socket->send($server_input);
        } else {
            # do a peek to see if data is still waiting. This will trigger the
            # 'connected' to turn false on remotely closed connections (ex: logoff)
            $server_socket->recv($server_input, 1, MSG_PEEK);
        }

        my $temp_input = '';
        $client_socket->recv($temp_input, 1);
        #say "CLIENT RECV END";
        if ($temp_input ne '') {
            $server_socket->send($temp_input);
            $last_send = time;
            $timeout_warning_sent = 0;
        }

        my $inactivity = time - $last_send;

        if ($inactivity > 120) {
            $self->_log->error("Client timeout. Disconnecting...");
            $client_socket->send(pack('C', 155) . ">>Connection closed due to inactivity!" . pack('C', 155));
            $server_socket->close;
        } elsif (!$timeout_warning_sent && $inactivity > 60) {
            $self->_log->warn("Sending client inactivity time out warning.");
            $client_socket->send(pack('C', 155) . ">>WARN: Inactivity time out! ");
            $timeout_warning_sent = 1;
        }

        #say "END OF LOOP :: C=" . $client_socket->connected . " :: S=" . $server_socket->connected;
    }

    $self->_log->info("Deleting connection lock file: " . $self->_conn_lock_file);
    unlink($self->_conn_lock_file) or do {
        $self->_log->fatal("Failed to delete lock file! :: $!");
    };

    $self->_log->info("Leaving client thread and closing connection for client: $client_ip...");
    $client_socket->close;



    return;
}



sub _send_client_busy_screen {
    my ($self, $client) = @_;

    my $busy_scr_file = $self->_config->get('busy_screen_file', '../templates/busy.ata');

    if (! -e $busy_scr_file) {
        my $dest_bbs_name = $self->_config->get('destination_bbs_name', 'BBS');
        $client->send("Sorry! it looks like the $dest_bbs_name is currently busy right now. Please try again later");
        return;
    }

    open(my $FH, "<", $busy_scr_file) or do {
        $self->_log->fatal("Missing $busy_scr_file ! :: $!");
        return;
    };

    my @data = <$FH>;
    close($FH);

    $client->send($_) foreach (@data);

    return;
}



sub _send_client_offline_screen {
    my ($self, $client) = @_;

    my $offline_scr_file = $self->_config->get('offline_screen_file', '../templates/offline.ata');

    if (! -e $offline_scr_file) {
        my $dest_bbs_name = $self->_config->get('destination_bbs_name', 'BBS');
        $client->send("Sorry! $dest_bbs_name is currently offline. Please try again later.");
        return;
    }

    open(my $FH, "<", $offline_scr_file) or do {
        $self->_log->fatal("Missing $offline_scr_file ! :: $!");
        return;
    };

    my @data = <$FH>;
    close($FH);

    $client->send($_) foreach (@data);

    return;
}




=head2 _is_client_ip_blocked
    Checks to see if the given client IP matches any of the configured
    blocked IP prefixes in the configuration. If a match is found,
    another check will be done to see if it's found in the allow list.
    If an allow entry is found, the ip is not blocked and 0 (false) is
    returned. Otherwise, 1 (true) is returned.

    If ip address is not in block list, 0 (false) is returned.
=cut
sub _is_client_ip_blocked {
    my ($self, $client_ip) = @_;
    return 1 if (!$client_ip);

    foreach my $blocked_ip_prefix ($self->_blocked_ip_prefixes->@*) {
        if ($client_ip =~ m/$blocked_ip_prefix/) {

            foreach my $allowed_ip_prefix ($self->_allowed_ip_prefixes->@*) {
                if ($client_ip =~ m/$allowed_ip_prefix/) {
                    $self->_log->warn("IP address: $client_ip is found in allowed ip list entry: $allowed_ip_prefix :: Block overidden!");
                    return 0;
                }
            }

            $self->_log->fatal("IP address: $client_ip is found in blocked ip list entry: $blocked_ip_prefix");
            return 1;
        }
    }
    return 0;
}



=head2 _thread_clean_up
    NOTE: RUNS IN OWN THREAD
    This method wakes up on a configured interval and joins any threads that may
    be left dangling after a user disconnects.
    It also handles cleaning up the call log database records.
=cut
sub _thread_clean_up {
    my ($self) = @_;

    my $sleep_duration = $self->_config->get('thread_cleanup_duration', 60);

    while ($is_running) {

        $self->_log->info("Clean up thread is running...");
        try {

            foreach my $joinable ( threads->list(threads::joinable) ) {
                $self->_log->info("Joing joinable tid: " . $joinable->tid);
                $joinable->join;
            }

            $self->_log->info("Clean up thread complete. Sleeping for: $sleep_duration");
        } catch ($error) {
            $self->_log->fatal("Error in thread clean up! :: Sleeping for $sleep_duration :: $error");
        }

        sleep $sleep_duration;
    }
    return;
}



1;
