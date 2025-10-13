package BSCF::Configuration::Config;

use v5.34;

use Carp;
use Config::Tiny;
use FindBin qw($Bin);

sub new {
    my ($class, %args) = @_;

    my $log = BSCF::Log::Logger->new(name => $class);

    my $config_file = $args{config} // "$Bin/../config.ini";

    # TODO : give option to pass section instead of package name
    my $package = $args{package} // "_"; #default to root level section
    $package =~ s/^.*::|\s*$//g; # don't care about namespace, just package name

    my $config = Config::Tiny->read($config_file)->{$package};
    confess "Failed to read config file: $config_file :: " . $Config::Tiny::errstr if ($Config::Tiny::errstr);

    $log->info("Built config for $package");

    my $self = {
        config => $config,
        log => $log,
        section => $package,
    };

    return bless($self, $class);
}

sub _log {
    return shift->{log};
}

sub _config {
    return shift->{config};
}

sub _section {
    return shift->{section};
}

=head2 get
    Gets a config from the config file for a given section and key. Sections are
    decided by callers __PACKAGE__ name set in constructor. Environment variables
    override any values set in config file.

    Env variable format is "PACKAGENAME_CONFIG_KEY" (all uppercase);

    Args:
        config_key - config value to get from the package's section
        default (optional) - default value to use (default default is "")
=cut
sub get {
    my ($self, $config_key, $default_value) = @_;
    $config_key //= confess "Missing config key call to get_config";
    $default_value //= "";

    $self->_log->debug("Getting config for: " . $self->_section . " :: $config_key");

    # check if env var is set up and if so, use that instead.
    my $env_var = uc($self->_section . "_" . $config_key);
    if (exists $ENV{$env_var}) {
        if ($ENV{$env_var} !~ m/^\s*$/) {
            $self->_log->warn("Using environment variable: $env_var for config: " . $self->_section . " :: $config_key");
            return $ENV{$env_var};
        }
    }

    return $self->_config->{$config_key} // $default_value;
}

1;
