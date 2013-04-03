package Test::Network;
use strict;
use base 'Exporter';
use Test::More;
use Carp qw(croak);
use IO::Socket::IP;
use LWP::Simple qw(get);
use LWP::UserAgent;
use Socket qw(AF_INET AF_INET6 getaddrinfo);
use Scalar::Util qw(dualvar);
use Net::HTTPS 1.75;  # Supports IO::Socket::IP for ipv6
use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(decode_base64);

our @EXPORT = qw(
    accepts
    contains
    pings
    redirects
    same_ip
    ssh
);
push @EXPORT, @Test::More::EXPORT;

use v5.14;  # ipv6

our $TODO;
our $AF;

my $host_re = qr/[A-Za-z0-9.-]+/;

sub ipv4::import   { $^H{noipv4}   = 0; }
sub ipv4::unimport { $^H{noipv4}   = 1; }
sub ipv6::import   { $^H{ipv6todo} = 0; }
sub ipv6::unimport { $^H{ipv6todo} = 1; }

$INC{"ipv4.pm"} = "fake";
$INC{"ipv6.pm"} = "fake";

sub dualstack (&@) {
    no strict 'refs';

    my $sub = shift;

    my $caller = (caller 1)[0];
    my $ctrlh  = (caller 1)[10];

    local $AF = dualvar(AF_INET, "IPv4");
    &$sub unless $ctrlh->{noipv4};

    local $AF = dualvar(AF_INET6, "IPv6");
    local $TODO = $ctrlh->{ipv6todo} ? "No IPv6 yet" : ${"$caller\::TODO"};
    &$sub;
}

HACK_FOR_LWP_IPV6: {
    use Net::HTTP;
    s/IO::Socket::INET/IO::Socket::IP/ for @Net::HTTP::ISA;
}

sub pings {
    my ($host) = shift =~ /^($host_re)$/ or croak "Invalid hostname";

    dualstack {
        my $cmd = $AF == AF_INET6 ? "ping6" : "ping";
        my $counter = 0;
        my $r = -1;
        $r = system("$cmd -qc 1 $host >/dev/null 2>&1")
            until $r == 0 or ++$counter == 3;
        Test::More::is($r, 0, "$host responds to ICMP ping ($AF)");
    };
}

sub accepts {
    my ($host) = shift =~ /^($host_re)$/ or croak "Invalid hostname";
    my @ports = map /([0-9]+)/g, @_;

    for my $p (@ports) {
        dualstack {
            my $s = IO::Socket::IP->new(
                PeerAddr => $host,
                PeerPort => $p,
                Proto    => 'tcp',
                Timeout  => 1,
                Family   => $AF,
            );
            Test::More::ok(
                $s,
                "$host accepts a TCP connection at port $p ($AF)"
            );
        };
    }
}

sub contains {
    my ($url, $regex) = @_;
    my $name = "$url contains $regex";
    if (not ref $regex) {
        $regex = quotemeta $regex;
    }
    my $ua = LWP::UserAgent->new(max_redirect => 0);

    dualstack {
        subtest("$name ($AF)", sub {
            local @LWP::Protocol::http::EXTRA_SOCK_OPTS = (Family => $AF);
            my $response = $ua->get( $url );
            is $response->code, 200, "$url returns HTTP status 200";
            ok $response->content =~ /$regex/, "$name ($AF)";
        });
    };
}

sub redirects {
    my ($urlA, $urlB) = @_;
    my $ua = LWP::UserAgent->new(max_redirect => 0);

    dualstack {
        subtest( "$urlA redirects to $urlB ($AF)", sub {
            local @LWP::Protocol::http::EXTRA_SOCK_OPTS = (Family => $AF);
            my $response = $ua->get( $urlA );

            ok $response->code =~ /^30[1237]$/,
                "HTTP response is a redirect ($AF)";
            ok my $location = $response->header("Location"),
                "Response contains Location header ($AF)";

            my $base = $response->base;
            my $uriA_abs = URI->new($location, $base)->abs($base);
            my $uriB_abs = URI->new($urlB, $base)->abs($base);
            is $uriA_abs, $uriB_abs,
                "Redirection target($uriA_abs) is $uriB_abs ($AF)";

            done_testing;
        });
    };
}

sub same_ip {
    my $names = join " and ", @_;
    my @hosts = @_;

    dualstack {
        my %unique = map { $_ => 1 } map {
            join "+", map { unpack "H*", $_ } sort map $_->{addr}, grep ref,
                getaddrinfo($_, undef, { family => $AF });
        } @hosts;

        delete $unique{''} if keys(%unique) == 1;  # Nothing resolved => fail

        is scalar keys %unique, 1, "$names have the same IP ($AF)";
    };
}

sub ssh {
    my ($host, $fingerprint) = @_;
    ($host, my $port) = $host =~ /^($host_re)(?::([0-9]+))?$/
        or croak "Invalid host:port";
    $port ||= 22;
    $fingerprint =~ s/://g;
    $fingerprint =~ /^[0-9a-f]{32}$/i or croak "Invalid fingerprint";

    dualstack {
        my $f = ($AF == AF_INET6 ? 6 : 4);
        my $key = `ssh-keyscan -$f -t rsa $host 2>/dev/null`;
        $key &&= (split " ", $key)[2];
        $key &&= md5_hex(decode_base64( $key ));
        is $key, lc $fingerprint,
            "SSH fingerprint for $host:$port is $fingerprint ($AF)";
    };
}


1;
__END__

=head1 NAME

Test::Network - Test network service availability

=head1 SYNOPSIS

    #!/usr/bin/perl
    use strict;
    use Test::Network;

    my @mailservers = qw(server1 server2 server3);

    for my $h (@mailservers) {
        pings $h;
        accepts $h, 25, 110, 143;
    }

    same_ip("imap.example.org", "pop3.example.org", "mail.example.org");

    {
        no ipv4;
        pings "ipv6only.example.org";
        redirects "http://example.org/" => "https://example.org/";
    }

    {
        no ipv6;
        pings "stillnoipv6.example.org";
        redirects "http://example.com/foo" => "/bar";
    }

    contains "http://example.net/", "Some string";
    contains "http://example.net/", qr/Some reg(ular )?ex(p|pression)?/";

    done_testing;  # Don't use a plan ;-)

=head1 DESCRIPTION

TAP (Test Anything Protocol) is a great way to test all kinds of things, but
it is mostly just used in the field of programming. System administration,
however, needs testing too. This is generally performed by dedicated big
monitoring systems, but it can be convenient to bundle things in a test suite.

This module provides some simple functions, all exported by default, to test
the availability of network services. It does not currently do pervasive tests.

In addition to this module's own functions, all of the functions exported by
Test::More are also passed on; this is mostly useful for C<done_testing>.

=head2 Exported functions

=over 4

=item pings $host

Tests whether the host responds to ICMP echo.

=item accepts $host, @ports

Tests TCP connections. Does one test per address family per port.

=item contains $url, $match

Tests whether the web page at $url matches the given string or regex.

=item redirects $urlA, $urlB

Tests whether $urlA is an HTTP redirect to $urlB. $urlB may be given as a
relative or absolute URL.

=item same_ip @hosts

Tests whether all of the given hosts resolve to exactly the same IP addresses.

=item ssh $host, $fingerprint

Tests whether the SSH RSA fingerprint of the host is the expected one. C<$host>
may be C<host> or C<host:port>. The fingerprint may be given with or without
colons.

=back

=head2 Lexical pragmas

=over 4

=item no ipv4;

Disables testing IPv4. Can be re-enabled with C<use ipv4;>.

=item no ipv6;

Makes IPv6 tests "TODO" tests that are expected to fail. By design, it does not
actually disable IPv6 testing. The TODO status can be undone for consequent
tests with C<use ipv6;>.

=back

=head1 IDEAS

SSL/TLS expiry

DNS resolver

munin df, munin load

=head1 AUTHOR

Juerd Waalboer <juerd@tnx.nl>

=head1 LICENSE

Pick your favourite OSI approved license :)

http://www.opensource.org/licenses/alphabetical
