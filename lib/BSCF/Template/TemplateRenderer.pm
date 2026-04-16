package BSCF::Template::TemplateRenderer;

use v5.34;

use Carp;
use Config::Tiny;
use Exporter qw(import);
use FindBin qw($Bin);

use BSCF::Configuration::Config;
use BSCF::Log::Logger;

use constant {
    BUSY_TEMPLATE => 'busy_screen',
    OFFLINE_TEMPLATE => 'offline_screen',
    CONNECT_TEMPLATE => 'connect_screen',
};

our @EXPORT_OK = qw(
    BUSY_TEMPLATE
    OFFLINE_TEMPLATE
    CONNECT_TEMPLATE
);

sub new {
    my ($class, %args) = @_;

    my $log = BSCF::Log::Logger->new(name => $class);
    my $config = BSCF::Configuration::Config->new(package => __PACKAGE__);
    my @valid_templates = (BUSY_TEMPLATE, OFFLINE_TEMPLATE, CONNECT_TEMPLATE);

    my $self = {
        config => $config,
        log => $log,
        valid_templates => \@valid_templates,
    };

    return bless($self, $class);
}

sub _log {
    return shift->{log};
}

sub _config {
    return shift->{config};
}


sub _valid_templates {
    return shift->{valid_templates};
}


sub render {
    my ($self, $client, $template_type) = @_;

    $self->_log->info("Rendering template: $template_type");

    if (!grep(/^\Q$template_type\E$/, $self->_valid_templates->@*)) {
        $self->_log->fatal("Invalid template type: $template_type :: Sending client error message");
        $client->send("Sorry, an error has occurred.");
        return;
    }

    my $file = $self->_config->get($template_type . '_file', '');
    my $msg = $self->_config->get($template_type . '_msg', 'Sorry! An error has occurred');

    if (! -e $file) {
        $client->send($msg);
        return;
    }

    open(my $FH, "<", $file) or do {
        $self->_log->fatal("Missing $file ! :: $!");
        $client->send($msg);
        return;
    };

    my @data = <$FH>;
    close($FH);

    $client->send($_) foreach (@data);

    return;
}



1;
