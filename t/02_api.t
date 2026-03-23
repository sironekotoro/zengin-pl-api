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

subtest 'GET /api/meta returns metadata json' => sub {
    my $res = request($app, 'GET', '/api/meta');

    is($res->{status}, 200, 'status is 200');
    ok(exists $res->{json}->{api}, 'api exists');
    ok(exists $res->{json}->{backend}, 'backend exists');
    ok(exists $res->{json}->{data}, 'data exists');
    is($res->{json}->{api}->{name}, 'zengin-pl-api', 'default api.name is zengin-pl-api');
    is($res->{json}->{backend}->{class}, 'Zengin::Pl', 'backend.class is Zengin::Pl');
    is($res->{json}->{backend}->{base_url}, TestBackend::BASE_URL(), 'backend.base_url exists');
    is($res->{json}->{data}->{source}, TestBackend::BASE_URL(), 'data.source exists');
    ok(!defined $res->{json}->{api}->{version}, 'api.version is null when unset');
};

subtest 'GET /api/meta reflects APP_* environment variables' => sub {
    local $ENV{APP_NAME} = 'zengin-pl-api-cloudrun';
    local $ENV{APP_VERSION} = '0.1.0';
    local $ENV{APP_GIT_SHA} = 'abc1234';
    local $ENV{APP_BUILD_TIME} = '2026-03-24T00:40:00Z';

    my $meta_app = Zengin::PL::API->new(
        backend => TestBackend->new,
    )->to_app;

    my $res = request($meta_app, 'GET', '/api/meta');

    is($res->{status}, 200, 'status is 200');
    is($res->{json}->{api}->{name}, 'zengin-pl-api-cloudrun', 'api.name reflects APP_NAME');
    is($res->{json}->{api}->{version}, '0.1.0', 'api.version reflects APP_VERSION');
    is($res->{json}->{api}->{git_sha}, 'abc1234', 'api.git_sha reflects APP_GIT_SHA');
    is($res->{json}->{api}->{build_time}, '2026-03-24T00:40:00Z', 'api.build_time reflects APP_BUILD_TIME');
};

subtest 'GET /api/banks/0001/branches/001 returns branch json' => sub {
    my $res = request($app, 'GET', '/api/banks/0001/branches/001');

    is($res->{status}, 200, 'status is 200');
    is($res->{json}->{bank}->{code}, '0001', 'bank.code exists');
    ok(defined $res->{json}->{bank}->{name}, 'bank.name exists');
    is($res->{json}->{branch}->{code}, '001', 'branch.code exists');
    ok(defined $res->{json}->{branch}->{name}, 'branch.name exists');
};

subtest 'GET /api/banks/0001/branches?name=東京 returns branches array' => sub {
    my $res = request(
        $app,
        'GET',
        '/api/banks/0001/branches',
        'name=' . uri_escape_utf8('東京'),
    );

    is($res->{status}, 200, 'status is 200');
    ok(ref $res->{json}->{branches} eq 'ARRAY', 'branches is an array');
    ok(@{$res->{json}->{branches}} >= 1, 'branches contains at least one item');
};

subtest 'GET /api/banks/9999/branches/001 returns bank json error' => sub {
    my $res = request($app, 'GET', '/api/banks/9999/branches/001');

    is($res->{status}, 404, 'status is 404');
    is($res->{json}->{error}->{code}, 'bank_not_found', 'error code is bank_not_found');
};

subtest 'GET /api/banks/0001/branches/999 returns branch json error' => sub {
    my $res = request($app, 'GET', '/api/banks/0001/branches/999');

    is($res->{status}, 404, 'status is 404');
    is($res->{json}->{error}->{code}, 'branch_not_found', 'error code is branch_not_found');
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

    use constant BASE_URL => 'https://example.invalid/zengin-data';

    sub new { bless {}, shift }

    sub base_url { return BASE_URL }

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
        my ($self, $bank_term, $branch_term) = @_;

        if (defined $branch_term) {
            return [] if $bank_term ne '0001' || $branch_term ne '東京';

            return [
                {
                    code => '001',
                    name => '東京営業部',
                    hira => 'とうきよう',
                    kana => 'トウキヨウ',
                    roma => 'toukiyou',
                },
            ];
        }

        return [] if $bank_term ne 'みずほ';

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

    sub get_branch {
        my ($self, $bank_code, $branch_code) = @_;

        return if $bank_code ne '0001';
        return if $branch_code eq '999';

        return {
            code => '001',
            name => '東京営業部',
            hira => 'とうきよう',
            kana => 'トウキヨウ',
            roma => 'toukiyou',
        };
    }
}
