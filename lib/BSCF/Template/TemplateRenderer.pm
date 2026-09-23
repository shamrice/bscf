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
    MAX_CONNECTIONS_TEMPLATE => 'max_connections',

    RENDER_MODE_FILE => 'FILE',
    RENDER_MODE_MSG => 'MSG',
    RENDER_MODE_ALL => 'ALL',
    RENDER_MODE_NONE => 'NONE',
};

our @EXPORT_OK = qw(
    BUSY_TEMPLATE
    OFFLINE_TEMPLATE
    CONNECT_TEMPLATE
    MAX_CONNECTIONS_TEMPLATE
);

sub new {
    my ($class, %args) = @_;

    my $log = BSCF::Log::Logger->new(name => $class);
    my $config = BSCF::Configuration::Config->new(package => __PACKAGE__);
    my @valid_templates = (BUSY_TEMPLATE, OFFLINE_TEMPLATE, CONNECT_TEMPLATE);

    my $render_mode = uc($config->get('render_mode', RENDER_MODE_FILE));

    my @valid_render_modes = (RENDER_MODE_FILE, RENDER_MODE_MSG, RENDER_MODE_ALL, RENDER_MODE_NONE);
    if (!grep(/^\Q$render_mode\E$/, @valid_render_modes)) {
        $log->error("Invalid render mode configured: $render_mode :: Valid modes: [" . join(',', @valid_render_modes) . "] :: Defaulting to mode: " . RENDER_MODE_FILE);
        $render_mode = RENDER_MODE_FILE;
    }

    my %template_cache;

    # Populate template file cache for modes that send the template files.
    if ($render_mode eq RENDER_MODE_FILE || $render_mode eq RENDER_MODE_ALL) {
        foreach my $template_type (@valid_templates) {
            my @temp_template_data;
            my $file = $config->get($template_type . '_file', '');
            if (! -e $file) {
                $log->error("Template file was not found for template: $template_type!");
                next;
            }

            open(my $FH, "<", $file) or do {
                $log->fatal("Missing or error reading: $file ! :: $!");
                next;
            };

            @temp_template_data = <$FH>;
            close($FH);

            $template_cache{$template_type} = \@temp_template_data;
        }
    }

    my $self = {
        config => $config,
        log => $log,
        render_mode => $render_mode,
        valid_templates => \@valid_templates,
        template_cache => \%template_cache,
    };

    return bless($self, $class);
}

sub _log {
    return shift->{log};
}

sub _config {
    return shift->{config};
}

sub _render_mode {
    return shift->{render_mode};
}

sub _valid_templates {
    return shift->{valid_templates};
}

sub _template_cache {
    return shift->{template_cache} // { };
}


sub render {
    my ($self, $client, $template_type) = @_;

    $self->_log->info("Rendering template: $template_type");

    return if ($self->_render_mode eq RENDER_MODE_NONE);

    if (!grep(/^\Q$template_type\E$/, $self->_valid_templates->@*)) {
        $self->_log->fatal("Invalid template type: $template_type :: Sending client error message");
        $client->send("Sorry, an error has occurred.");
        return;
    }

    my $msg = $self->_config->get($template_type . '_msg', 'Sorry! An error has occurred');

    if ($self->_render_mode eq RENDER_MODE_MSG) {
        $client->send($msg);
        return;
    }

    my $template_data = $self->_template_cache->{$template_type} // [];
    my $is_send_msg = ($self->_render_mode eq RENDER_MODE_ALL || !scalar $template_data->@*) ? 1 : 0;

    $client->send($_) foreach ($template_data->@*);
    $client->send($msg) if ($is_send_msg);

    return;
}



1;
