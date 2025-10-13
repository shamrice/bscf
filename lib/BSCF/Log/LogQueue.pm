package BSCF::Log::LogQueue;

use v5.34;

use threads;

use feature qw(isa try);

use Carp;
use Data::Dumper;
use Log::Log4perl qw(get_logger);
use POSIX qw(strftime);
use Thread::Queue;

use FindBin qw($Bin);
use lib("$Bin/../lib");

no warnings qw(experimental::try);

=pod
    A shared log queue for all BSCF Logger instances
    across all spawned threads.

    Enqueued log entries are sent to the thread queue for
    further processing.

    The log_queue_handler_thread is a separate thread that
    is spun up by the main thread that handles the actual logging
    with log4perl. This is to maintain a single file handle
    between all logging instead opening a separate one for
    every single thread and logger.
=cut



my $log_queue = Thread::Queue->new;


=head2 enqueue_log
    Puts the given log entry onto the thread queue to be picked
    up by the queue handler
=cut
sub enqueue_log {
    my ($log_name, $level, $text) = @_;

    return if (!$level || !$text);

    $log_queue->enqueue({
        log_name => $log_name,
        level => $level,
        text => $text
    });

    return;
}



sub _init_logs {
    my $log_config = "$Bin/../log4perl.conf";

    if (!-e $log_config) {
        warn "Cannot find log4perl config file: $log_config! Logs will not be initialized!";
        return;
    }

    # Rename any current rotating log file to a named value so not to get overwritten.
    open(my $FH, "<", $log_config) or die "Cannot open log4perl.conf! :: $log_config :: $!";
    my @log_config_contents = <$FH>;
    close($FH);

    my $log_rotate_filename = '';
    foreach my $config_line (@log_config_contents) {
        if ($config_line =~ m/log4perl\.appender\.LogRotateFile\.filename=/i) {
            $log_rotate_filename = (split('=', $config_line))[1];
            chomp($log_rotate_filename);
            if (-e $log_rotate_filename) {
                rename($log_rotate_filename, $log_rotate_filename . '.' . strftime('%Y%m%d%H%M%S', localtime()));
            }
            last;
        }
    }

    if (!Log::Log4perl->initialized) {
        Log::Log4perl->init_once($log_config);
    }


    # Configure log rotate to use date in file names instead if configured to do so..
    my $log_rotate_appender = Log::Log4perl->appender_by_name('LogRotateFile');

    if ($log_rotate_appender) {

        if ($log_rotate_appender->{params}->{use_datetime_in_rotation_filename}) {
            $log_rotate_appender->{post_rotate} = sub {
                my ($filename, $idx, $fileRotate) = @_;

                if ($idx == 1) {
                    use POSIX qw(strftime);
                    my $basename = $fileRotate->filename();
                    my $newfilename = $basename . '.' . strftime('%Y%m%d%H%M%S', localtime());
                    rename($filename, $newfilename);
                }
                return;
            };
        }
    }

    return 1;
}



=head2 log_queue_handler_thread
    This sub is meant to be run a separate thread that is
    spawned from the main app thread. It handles reading log
    items from the queue and logging them to the configured
    log4perl log file.

    WARNING: If any error occurs, it will try indefinitely to
             re-read the queue!
=cut
sub log_queue_handler_thread {

    if (!_init_logs) {
        warn "Failed to init logs!";
        return;
    }

    my $logger = get_logger;

    while (1) {
        try {
            while (defined(my $log_item = $log_queue->dequeue())) {

                my $log_text = $log_item->{text} || do {
                    warn "Missing/empty log text passed to log queue. Cannot log empty messages.";
                    next;
                };

                my $log_level = $log_item->{level} // 'info';
                my $log_name = $log_item->{log_name} // 'UNKNOWN';
                $logger->$log_level('[' . $log_name . '] ' . $log_text);
            }
        } catch ($error) {
            carp(strftime('%F %T', gmtime) . " [FATAL] [LOG QUEUE ERROR] Fatal error processing log queue :: $error");
        }
    }
    return;
}


1;
