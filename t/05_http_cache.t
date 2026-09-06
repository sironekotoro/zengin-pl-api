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

subtest 'GET /api/meta publishes a short-lived cache policy and ETag' => sub {
    my $res = request($app, 'GET', '/api/meta');

    is($res->{status}, 200, 'status is 200');
    is(header($res, 'Cache-Control'), 'public, max-age=60', '/api/meta uses a short TTL');
    like(header($res, 'ETag'), qr/\A"[0-9a-f]{64}"\z/, 'ETag is a quoted sha256 hex digest');
};

subtest 'GET /api/banks/0001 publishes the default cache policy and ETag' => sub {
    my $res = request($app, 'GET', '/api/banks/0001');

    is($res->{status}, 200, 'status is 200');
    is(header($res, 'Cache-Control'), 'public, max-age=300', 'bank lookup uses the default TTL');
    like(header($res, 'ETag'), qr/\A"[0-9a-f]{64}"\z/, 'ETag is a quoted sha256 hex digest');
};

subtest 'GET /api/banks/0001/branches/001 publishes cache headers' => sub {
    my $res = request($app, 'GET', '/api/banks/0001/branches/001');

    is($res->{status}, 200, 'status is 200');
    is(header($res, 'Cache-Control'), 'public, max-age=300', 'branch lookup uses the default TTL');
    ok(defined header($res, 'ETag'), 'ETag is present');
};

subtest 'identical requests produce a stable ETag' => sub {
    my $first  = request($app, 'GET', '/api/banks/0001');
    my $second = request($app, 'GET', '/api/banks/0001');

    is(header($first, 'ETag'), header($second, 'ETag'), 'ETag is stable across repeated requests');
    is($first->{body}, $second->{body}, 'response body is also unchanged');
};

subtest 'different search queries produce different ETags' => sub {
    my $mizuho = request(
        $app, 'GET', '/api/banks',
        'name=' . uri_escape_utf8('みずほ'),
    );
    my $mitsubishi = request(
        $app, 'GET', '/api/banks',
        'name=' . uri_escape_utf8('三菱'),
    );

    is($mizuho->{status}, 200, 'みずほ search returns 200');
    is($mitsubishi->{status}, 200, '三菱 search returns 200');
    isnt(header($mizuho, 'ETag'), header($mitsubishi, 'ETag'), 'different query variants get different ETags');
};

subtest 'a changed response body changes the ETag' => sub {
    my $before = request($app, 'GET', '/api/banks/0001');

    my $updated_app = Zengin::PL::API->new(
        backend => TestBackend->new(name => 'みずほ銀行'),
    )->to_app;
    my $after = request($updated_app, 'GET', '/api/banks/0001');

    isnt(header($before, 'ETag'), header($after, 'ETag'), 'ETag changes when the body changes');
};

subtest 'If-None-Match with the current ETag returns 304 with no body' => sub {
    my $first = request($app, 'GET', '/api/banks/0001');
    my $etag  = header($first, 'ETag');

    my $second = request(
        $app, 'GET', '/api/banks/0001', undef,
        headers => { HTTP_IF_NONE_MATCH => $etag },
    );

    is($second->{status}, 304, 'matching If-None-Match returns 304');
    is($second->{body}, q{}, '304 response has an empty body');
    is(header($second, 'ETag'), $etag, '304 still reports the ETag');
    is(header($second, 'Cache-Control'), 'public, max-age=300', '304 still reports Cache-Control');
    is(header($second, 'Access-Control-Allow-Origin'), '*', '304 still carries CORS headers');
};

subtest 'If-None-Match accepts multiple validators and weak comparison' => sub {
    my $first = request($app, 'GET', '/api/banks/0001');
    my $etag  = header($first, 'ETag');

    my $multi = request(
        $app, 'GET', '/api/banks/0001', undef,
        headers => { HTTP_IF_NONE_MATCH => qq{"stale-etag", $etag} },
    );
    is($multi->{status}, 304, 'a matching entry among several validators still returns 304');

    my $weak = request(
        $app, 'GET', '/api/banks/0001', undef,
        headers => { HTTP_IF_NONE_MATCH => "W/$etag" },
    );
    is($weak->{status}, 304, 'a weak (W/) validator is compared using weak comparison');
};

subtest 'If-None-Match: * always matches' => sub {
    my $res = request(
        $app, 'GET', '/api/banks/0001', undef,
        headers => { HTTP_IF_NONE_MATCH => '*' },
    );
    is($res->{status}, 304, 'wildcard If-None-Match returns 304');
};

subtest 'If-None-Match with a non-matching ETag returns a normal 200' => sub {
    my $res = request(
        $app, 'GET', '/api/banks/0001', undef,
        headers => { HTTP_IF_NONE_MATCH => '"does-not-match"' },
    );

    is($res->{status}, 200, 'non-matching If-None-Match falls through to 200');
    ok(defined $res->{json}->{bank}, 'the full body is still returned');
};

subtest 'error responses are not given a public cache policy' => sub {
    my $not_found = request($app, 'GET', '/api/banks/9999');
    is($not_found->{status}, 404, 'status is 404');
    my $not_found_cache_control = header($not_found, 'Cache-Control');
    ok(
        !defined $not_found_cache_control || $not_found_cache_control !~ /public|max-age/,
        '404 response is not marked as a long-lived public cache',
    );
    ok(!defined header($not_found, 'ETag'), '404 response has no ETag');

    my $missing_name = request($app, 'GET', '/api/banks');
    is($missing_name->{status}, 400, 'status is 400');
    my $missing_name_cache_control = header($missing_name, 'Cache-Control');
    ok(
        !defined $missing_name_cache_control || $missing_name_cache_control !~ /public|max-age/,
        '400 response is not marked as a long-lived public cache',
    );

    my $method_not_allowed = request($app, 'POST', '/api/meta');
    is($method_not_allowed->{status}, 405, 'status is 405');
    my $method_not_allowed_cache_control = header($method_not_allowed, 'Cache-Control');
    ok(
        !defined $method_not_allowed_cache_control || $method_not_allowed_cache_control !~ /public|max-age/,
        '405 response does not reuse the success cache policy',
    );

    my $error_backend = TestBackend->new(fail => 1);
    my $error_app = Zengin::PL::API->new(backend => $error_backend)->to_app;
    my ($backend_error, $warning);
    {
        local $SIG{__WARN__} = sub { $warning .= join q{}, @_ };
        $backend_error = request($error_app, 'GET', '/api/banks/0001');
    }
    is($backend_error->{status}, 500, 'status is 500');
    my $backend_error_cache_control = header($backend_error, 'Cache-Control');
    ok(
        !defined $backend_error_cache_control || $backend_error_cache_control !~ /public|max-age/,
        '500 response is not marked as a long-lived public cache',
    );
    ok(!defined header($backend_error, 'ETag'), '500 response has no ETag');
};

subtest 'the Slack endpoint is not affected by the API cache policy' => sub {
    my $res = request($app, 'OPTIONS', '/slack/zengin');

    is($res->{status}, 405, 'Slack endpoint keeps its existing method restriction');
    ok(!defined header($res, 'Cache-Control'), 'Slack response has no Cache-Control header');
    ok(!defined header($res, 'ETag'), 'Slack response has no ETag header');
};

done_testing;

sub request {
    my ($app, $method, $path, $query_string, %args) = @_;

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
        %{ $args{headers} || {} },
    });

    my $body = join q{}, @{$res->[2]};
    my %headers = @{$res->[1]};
    my $decoded_json;
    if (($headers{'Content-Type'} || q{}) =~ m{\Aapplication/json\b}) {
        $decoded_json = decode_json($body);
    }

    return {
        status => $res->[0],
        headers => $res->[1],
        body => $body,
        json => $decoded_json,
    };
}

sub header {
    my ($res, $name) = @_;
    my %headers = @{$res->{headers}};
    return $headers{$name};
}

{
    package TestBackend;

    use strict;
    use warnings;

    use constant BASE_URL => 'https://example.invalid/zengin-data';

    sub new {
        my ($class, %args) = @_;
        return bless { name => $args{name} || 'みずほ', fail => $args{fail} }, $class;
    }

    sub meta {
        return {
            class    => 'Zengin::Pl',
            version  => '0.01',
            base_url => BASE_URL,
            source   => {
                kind       => 'zengin-data-mirror',
                revision   => 'abc1234',
                updated_at => '20260630',
            },
        };
    }

    sub get_bank {
        my ($self, $bank_code) = @_;

        die "backend failed\n" if $self->{fail};
        return if $bank_code eq '9999';

        return {
            code => '0001',
            name => $self->{name},
            hira => 'みずほ',
            kana => 'ミズホ',
            roma => 'mizuho',
        };
    }

    sub search {
        my ($self, $bank_term) = @_;

        return [
            {
                code => '0001',
                name => 'みずほ',
                hira => 'みずほ',
                kana => 'ミズホ',
                roma => 'mizuho',
            },
        ] if $bank_term eq 'みずほ';

        return [
            {
                code => '0005',
                name => '三菱ＵＦＪ',
                hira => 'みつびしゆーえふじえい',
                kana => 'ミツビシユーエフジエイ',
                roma => 'mitsubishiyu-efujiei',
            },
        ] if $bank_term eq '三菱';

        return [];
    }

    sub get_branch {
        my ($self, $bank_code, $branch_code) = @_;

        return if $bank_code ne '0001' || $branch_code ne '001';

        return {
            code => '001',
            name => '東京営業部',
            hira => 'とうきよう',
            kana => 'トウキヨウ',
            roma => 'toukiyou',
        };
    }
}
