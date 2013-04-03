#!/usr/bin/perl -w
use strict;

my $host = shift;
my @ports = `nmap --open -oG - $host | grep Ports` =~ m[(\d+)/open/tcp]g
    or die "No open ports\n";

my $ports = join ", ", @ports;

print <<"END";
#!/usr/bin/perl
use strict;
use Test::Network;

my \$host = "$host";
pings \$host;
accepts \$host, $ports;

done_testing;

# vim: set ft=perl
END


