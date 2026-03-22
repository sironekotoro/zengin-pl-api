use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use JSON::PP qw(decode_json);
use Test::More;
use URI::Escape qw(uri_escape_utf8);

use Zengin::PL::API;

my $app = Zengin::PL::API->new(
    backend => TestBackend->new,
)->to_app;

subtest 'GET /api/banks/0001 returns bank json' => sub {
    my $res = request($app, 'GET', '/api/banks/0001');

    is($res->{status}, 200, 'status is 200');
    is($res->{json}->{bank}->{code}, '0001', 'bank.code exists');
    ok(defined $res->{json}->{bank}->{name}, 'bank.name exists');
};

subtest 'GET /api/banks?name=みずほ returns banks array' => sub {
    my $res = request(
        $app,
        'GET',
        '/api/banks',
        'name=' . uri_escape_utf8('みずほ'),
    );

    is($res->{status}, 200, 'status is 200');
    ok(ref $res->{json}->{banks} eq 'ARRAY', 'banks is an array');
    ok(@{$res->{json}->{banks}} >= 1, 'banks contains at least one item');
};

subtest 'GET /api/banks/9999 returns json error' => sub {
    my $res = request($app, 'GET', '/api/banks/9999');

    is($res->{status}, 404, 'status is 404');
    is($res->{json}->{error}->{code}, 'bank_not_found', 'error code is bank_not_found');
};

done_testing;

sub request {
    my ($app, $method, $path, $query_string) = @_;

    my $input = q{};
    open my $input_fh, '<', \$input or die "Failed to open in-memory input: $!";

    my $res = $app->({
        REQUEST_METHOD    => $method,
        PATH_INFO         => $path,
        QUERY_STRING      => $query_string || q{},
        REQUEST_URI       => $path . (defined $query_string && length $query_string ? "?$query_string" : q{}),
        SCRIPT_NAME       => q{},
        SERVER_NAME       => 'localhost',
        SERVER_PORT       => 5000,
        'psgi.version'    => [1, 1],
        'psgi.url_scheme' => 'http',
        'psgi.input'      => $input_fh,
        'psgi.errors'     => *STDERR,
        'psgi.multithread' => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 0,
        'psgi.nonblocking'  => 0,
    });

    my $body = join q{}, @{$res->[2]};

    return {
        status => $res->[0],
        headers => $res->[1],
        body => $body,
        json => decode_json($body),
    };
}

{
    package TestBackend;

    use strict;
    use warnings;

    sub new { bless {}, shift }

    sub get_bank {
        my ($self, $bank_code) = @_;

        return if $bank_code eq '9999';

        return {
            code => '0001',
            name => 'みずほ',
            hira => 'みずほ',
            kana => 'ミズホ',
            roma => 'mizuho',
        };
    }

    sub search {
        my ($self, $name) = @_;

        return [] if $name ne 'みずほ';

        return [
            {
                code => '0001',
                name => 'みずほ',
                hira => 'みずほ',
                kana => 'ミズホ',
                roma => 'mizuho',
            },
        ];
    }
}
