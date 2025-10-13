package BSCF::Log::Logger;

use v5.34;

use threads;

use feature qw(isa try);

use Carp;

use BSCF::Log::LogQueue;

use constant {
    LOG_LEVEL_TRACE => 'trace',
    LOG_LEVEL_DEBUG => 'debug',
    LOG_LEVEL_INFO => 'info',
    LOG_LEVEL_WARN => 'warn',
    LOG_LEVEL_ERROR => 'error',
    LOG_LEVEL_FATAL => 'fatal',
};

no warnings qw(experimental::try);


=pod
    A simple log wrapper that passes the log request given
    to the shared log queue to be processed. This allows it
    to be a drop in replacement for calling log4perl directly
    while maintaining a single file handle for logging between
    threads.
=cut

sub new {
    my ($class, %args) = @_;

    my $logger_name = $args{name} // '';

    my $self = {
        logger_name => $logger_name,
    };

    return bless($self, $class);
}


sub _logger_name {
    return shift->{logger_name};
}

sub trace {
    my ($self, $text) = @_;
    return $self->_logger(LOG_LEVEL_TRACE, $text);
}

sub debug {
    my ($self, $text) = @_;
    return $self->_logger(LOG_LEVEL_DEBUG, $text);
}

sub info {
    my ($self, $text) = @_;
    return $self->_logger(LOG_LEVEL_INFO, $text);
}


sub warn {
    my ($self, $text) = @_;
    return $self->_logger(LOG_LEVEL_WARN, $text);
}


sub error {
    my ($self, $text) = @_;
    return $self->_logger(LOG_LEVEL_ERROR, $text);
}

sub fatal {
    my ($self, $text) = @_;
    return $self->_logger(LOG_LEVEL_FATAL, $text);
}


sub _logger {
    my ($self, $level, $text) = @_;
    return if (!$text);
    try {
        BSCF::Log::LogQueue::enqueue_log($self->_logger_name, $level, $text);
    } catch ($enqueue_error) {
        carp("Failed to enqueue log item. logger: " . $self->_logger_name . " :: level: $level :: text: $text :: Error: $enqueue_error");
    }
    return;
}


1;
