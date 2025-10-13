# https://metacpan.org/pod/distribution/Module-CPANfile/lib/cpanfile.pod
#
# cpanm --installdeps -n .
#
requires 'perl', 'v5.34';
requires 'Carp';
requires 'Config::Tiny';
requires 'Date::Parse';
requires 'DateTime';
requires 'Exporter';
requires 'Fcntl';
requires 'File::Basename';
requires 'File::Copy';
requires 'File::Find';
requires 'File::Path';
requires 'File::Slurper';
requires 'FindBin';
requires 'IO::Socket::INET';
requires 'Log::Dispatch';
requires 'Log::Dispatch::FileRotate';
requires 'Log::Log4perl';
requires 'Path::Tiny';
requires 'POSIX';
requires 'Thread::Queue';
requires 'threads';
requires 'threads::shared';


on test => sub {
    requires 'Test::More';
};
