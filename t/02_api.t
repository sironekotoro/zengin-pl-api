use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

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
    is($res->{json}->{backend}->{version}, '0.01', 'backend.version exists');
    is($res->{json}->{backend}->{base_url}, TestBackend::BASE_URL(), 'backend.base_url exists');
    is($res->{json}->{data}->{source}->{kind}, 'zengin-data-mirror', 'data.source.kind exists');
    ok(exists $res->{json}->{data}->{source}->{revision}, 'data.source.revision key exists');
    ok(exists $res->{json}->{data}->{source}->{updated_at}, 'data.source.updated_at key exists');
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
    is($res->{json}->{branches}->[0]->{code}, '001', 'hash-backed branch search returns the matching branch');
};

subtest 'branch search filters the fetched branch list without backend search' => sub {
    my $backend = CountingBackend->new;
    my $counting_app = Zengin::PL::API->new(backend => $backend)->to_app;

    is(ref $backend->get_branches('0001'), 'HASH', 'test backend matches Zengin::Pl get_branches return type');
    $backend->{calls}->{get_branches} = 0;

    my @cases = (
        ['name', '東京', ['001']],
        ['kana', 'オオサカ', ['002']],
        ['hira', 'なごや', ['010']],
        ['code', '01', ['001', '010']],
        ['no match', '札幌', []],
        ['literal regular-expression characters', '.', []],
    );

    for my $case (@cases) {
        my ($label, $term, $expected_codes) = @{$case};
        my $res = request(
            $counting_app,
            'GET',
            '/api/banks/0001/branches',
            'name=' . uri_escape_utf8($term),
        );

        is($res->{status}, 200, "$label search returns 200");
        is_deeply(
            [map { $_->{code} } @{$res->{json}->{branches}}],
            $expected_codes,
            "$label search returns matching branches in code order",
        );
        is_deeply(
            [sort keys %{$_}],
            [qw(code name)],
            "$label search returns only code and name",
        ) for @{$res->{json}->{branches}};
    }

    is($backend->{calls}->{get_bank}, scalar @cases, 'get_bank is called once per request');
    is($backend->{calls}->{get_branches}, scalar @cases, 'get_branches is called once per request');
    is($backend->{calls}->{search} || 0, 0, 'search is not called');
};

subtest 'branch search keeps existing error responses' => sub {
    my $missing_name_backend = CountingBackend->new;
    my $missing_name_app = Zengin::PL::API->new(backend => $missing_name_backend)->to_app;
    my $missing_name = request($missing_name_app, 'GET', '/api/banks/0001/branches');

    is($missing_name->{status}, 400, 'missing name returns 400');
    is($missing_name->{json}->{error}->{code}, 'invalid_request', 'missing name error code is unchanged');
    is($missing_name_backend->{calls}->{get_bank}, 1, 'missing name still checks the bank once');
    is($missing_name_backend->{calls}->{get_branches} || 0, 0, 'missing name does not fetch branches');

    my $missing_bank_backend = CountingBackend->new;
    my $missing_bank_app = Zengin::PL::API->new(backend => $missing_bank_backend)->to_app;
    my $missing_bank = request(
        $missing_bank_app,
        'GET',
        '/api/banks/9999/branches',
        'name=' . uri_escape_utf8('東京'),
    );

    is($missing_bank->{status}, 404, 'missing bank returns 404');
    is($missing_bank->{json}->{error}->{code}, 'bank_not_found', 'missing bank error code is unchanged');
    is($missing_bank_backend->{calls}->{get_bank}, 1, 'missing bank is checked once');
    is($missing_bank_backend->{calls}->{get_branches} || 0, 0, 'missing bank does not fetch branches');

    my $error_backend = CountingBackend->new(fail_get_branches => 1);
    my $error_app = Zengin::PL::API->new(backend => $error_backend)->to_app;
    my $backend_error = request(
        $error_app,
        'GET',
        '/api/banks/0001/branches',
        'name=' . uri_escape_utf8('東京'),
    );

    is($backend_error->{status}, 500, 'backend error returns 500');
    is($backend_error->{json}->{error}->{code}, 'backend_error', 'backend error code is unchanged');
    is($error_backend->{calls}->{get_bank}, 1, 'backend error request checks the bank once');
    is($error_backend->{calls}->{get_branches}, 1, 'backend error request fetches branches once');
    is($error_backend->{calls}->{search} || 0, 0, 'backend error request does not call search');
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

    sub meta {
        return {
            class    => 'Zengin::Pl',
            version  => '0.01',
            base_url => BASE_URL,
            source   => {
                kind       => 'zengin-data-mirror',
                revision   => undef,
                updated_at => undef,
            },
        };
    }

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

    sub get_branches {
        my ($self, $bank_code) = @_;

        return {} if $bank_code ne '0001';

        return {
            '001' => {
                code => '001',
                name => '東京営業部',
                hira => 'とうきよう',
                kana => 'トウキヨウ',
                roma => 'toukiyou',
            },
        };
    }
}

{
    package CountingBackend;

    use strict;
    use warnings;

    sub new {
        my ($class, %args) = @_;
        return bless {
            calls => {},
            %args,
        }, $class;
    }

    sub get_bank {
        my ($self, $bank_code) = @_;
        $self->{calls}->{get_bank}++;
        return if $bank_code eq '9999';
        return {code => '0001', name => 'みずほ'};
    }

    sub get_branches {
        my ($self, $bank_code) = @_;
        $self->{calls}->{get_branches}++;
        die "branch backend failed\n" if $self->{fail_get_branches};

        return {
            '010' => {code => '010', name => '名古屋支店', hira => 'なごやしてん', kana => 'ナゴヤシテン'},
            '002' => {code => '002', name => '大阪支店', hira => 'おおさかしてん', kana => 'オオサカシテン'},
            '001' => {code => '001', name => '東京営業部', hira => 'とうきようえいぎょうぶ', kana => 'トウキヨウエイギヨウブ'},
        };
    }

    sub search {
        my ($self) = @_;
        $self->{calls}->{search}++;
        die "search must not be called\n";
    }
}
