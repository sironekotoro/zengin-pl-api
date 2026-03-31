use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use FindBin;
use lib "$FindBin::Bin/../lib";

use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP qw(decode_json);
use Test::More;
use URI::Escape qw(uri_escape_utf8);

use Zengin::PL::API;

local $ENV{SLACK_SIGNING_SECRET} = 'test-signing-secret';
local $ENV{SLACK_SIGNING_SECRETS} = undef;

my $app = Zengin::PL::API->new(
    backend => TestBackend->new,
)->to_app;

subtest 'POST /slack/zengin rejects invalid signature' => sub {
    my $res = slack_request($app, '0001', invalid_signature => 1);

    is($res->{status}, 401, 'status is 401');
    like($res->{body}, qr/Invalid Slack signature/, 'invalid signature is rejected');
};

subtest 'POST /slack/zengin accepts single legacy signing secret' => sub {
    local $ENV{SLACK_SIGNING_SECRET} = 'legacy-secret';
    local $ENV{SLACK_SIGNING_SECRETS} = undef;

    my $legacy_app = Zengin::PL::API->new(
        backend => TestBackend->new,
    )->to_app;

    my $res = slack_request($legacy_app, '0001', signing_secret => 'legacy-secret');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/銀行コード　　　　: 0001/, 'legacy single secret still works');
};

subtest 'POST /slack/zengin accepts any secret from SLACK_SIGNING_SECRETS' => sub {
    local $ENV{SLACK_SIGNING_SECRET} = 'legacy-secret';
    local $ENV{SLACK_SIGNING_SECRETS} = ' personal-secret, work-secret , ';

    my $multi_secret_app = Zengin::PL::API->new(
        backend => TestBackend->new,
    )->to_app;

    my $res = slack_request($multi_secret_app, '0001', signing_secret => 'work-secret');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/銀行コード　　　　: 0001/, 'matching secret from list is accepted');
};

subtest 'POST /slack/zengin rejects when no configured secret matches' => sub {
    local $ENV{SLACK_SIGNING_SECRET} = 'legacy-secret';
    local $ENV{SLACK_SIGNING_SECRETS} = 'personal-secret,work-secret';

    my $multi_secret_app = Zengin::PL::API->new(
        backend => TestBackend->new,
    )->to_app;

    my $res = slack_request($multi_secret_app, '0001', signing_secret => 'unknown-secret');

    is($res->{status}, 401, 'status is 401');
    like($res->{body}, qr/Invalid Slack signature/, 'unknown secret is rejected');
};

subtest 'POST /slack/zengin fails safely when no secret is configured' => sub {
    local $ENV{SLACK_SIGNING_SECRET} = undef;
    local $ENV{SLACK_SIGNING_SECRETS} = undef;

    my $no_secret_app = Zengin::PL::API->new(
        backend => TestBackend->new,
    )->to_app;

    my $res = slack_request($no_secret_app, '0001', signing_secret => 'test-signing-secret');

    is($res->{status}, 500, 'status is 500');
    like(
        $res->{body},
        qr/SLACK_SIGNING_SECRET or SLACK_SIGNING_SECRETS is not configured/,
        'missing secret configuration fails safely'
    );
};

subtest 'POST /slack/zengin returns bank detail' => sub {
    my $res = slack_request($app, '0001');

    is($res->{status}, 200, 'status is 200');
    is($res->{json}->{response_type}, 'ephemeral', 'response is ephemeral');
    like($res->{headers}->{'Content-Type'}, qr/\Aapplication\/json; charset=utf-8\z/, 'content type is utf-8 json');
    like($res->{json}->{text}, qr/銀行コード　　　　: 0001/, 'bank code is included');
    like($res->{json}->{text}, qr/銀行名　　　　　　: みずほ/, 'bank name is included');
    like($res->{json}->{text}, qr/銀行名（ひらがな）: みずほ/, 'bank hira label is included');
    like($res->{json}->{text}, qr/銀行名（カタカナ）: ミズホ/, 'bank kana label is included');
    like($res->{json}->{text}, qr/銀行名（ローマ字）: mizuho/, 'bank roma label is included');
};

subtest 'POST /slack/zengin returns help with metadata' => sub {
    local $ENV{APP_NAME} = 'zengin-pl-api-cloudrun';
    local $ENV{APP_VERSION} = '0.1.0';
    local $ENV{APP_GIT_SHA} = 'abc1234';
    local $ENV{APP_BUILD_TIME} = '2026-03-24T00:40:00Z';

    my $res = slack_request($app, 'help');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/使い方:/, 'usage header is included');
    like($res->{json}->{text}, qr!/zengin help!, 'help command is included');
    like($res->{json}->{text}, qr/メタ情報:/, 'meta section is included');
    like($res->{json}->{text}, qr/アプリ名　　　　　: zengin-pl-api-cloudrun/, 'app name is included');
    like($res->{json}->{text}, qr/アプリ版　　　　　: 0\.1\.0/, 'app version is included');
    like($res->{json}->{text}, qr/GitHub SHA　　　　: abc1234/, 'git sha is included');
    like($res->{json}->{text}, qr/ビルド日時　　　　: 2026-03-24T00:40:00Z/, 'build time is included');
    like($res->{json}->{text}, qr/backend class　　 : Zengin::Pl/, 'backend class is included');
    like($res->{json}->{text}, qr/data source kind　: zengin-data-mirror/, 'data source kind is included');
    like($res->{json}->{text}, qr/data base_url　　 : https:\/\/example\.invalid\/zengin-data/, 'data base_url is included');
};

subtest 'POST /slack/zengin returns sorted bank candidates in code block' => sub {
    my $res = slack_request($app, 'みずほ');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/\A銀行候補:\n```/m, 'bank candidates are wrapped in code block');
    like(
        $res->{json}->{text},
        qr/0001\s+みずほ\n0289\s+みずほ信託\n4859\s+埼玉みずほ農協/s,
        'bank candidates are ordered by exact match then code'
    );
};

subtest 'POST /slack/zengin returns bank and branch detail' => sub {
    my $res = slack_request($app, '0001 001');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/銀行コード　　　　: 0001/, 'bank section is included');
    like($res->{json}->{text}, qr/支店コード　　　　: 001/, 'branch code is included');
    like($res->{json}->{text}, qr/支店名　　　　　　: 東京営業部/, 'branch name is included');
};

subtest 'POST /slack/zengin resolves exact bank name before branch code lookup' => sub {
    my $res = slack_request($app, 'みずほ 001');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/銀行コード　　　　: 0001/, 'exact bank name resolves to 0001');
    like($res->{json}->{text}, qr/支店コード　　　　: 001/, 'branch detail is returned');
};

subtest 'POST /slack/zengin returns branch list' => sub {
    my $res = slack_request($app, '0001 東京');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/^```/m, 'branch list is wrapped in code block');
    like(
        $res->{json}->{text},
        qr/0001\s+みずほ\s+001\s+東京営業部\n0001\s+みずほ\s+078\s+東京法人営業部\n0001\s+みずほ\s+110\s+東京中央/s,
        'branch list is ordered by branch code'
    );
};

subtest 'POST /slack/zengin resolves exact bank name before branch name lookup' => sub {
    my $res = slack_request($app, 'みずほ 横浜');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/^```/m, 'branch list is wrapped in code block');
    like(
        $res->{json}->{text},
        qr/0001\s+みずほ\s+510\s+横浜駅前支店\n0001\s+みずほ\s+520\s+横浜支店/s,
        'branch search is limited to the exact matched bank'
    );
    unlike($res->{json}->{text}, qr/0289\s+みずほ信託/, 'cross-bank results are not included');
};

subtest 'POST /slack/zengin returns usage for invalid input' => sub {
    my $res = slack_request($app, '0001 001 extra');

    is($res->{status}, 200, 'status is 200');
    like($res->{json}->{text}, qr/使い方:/, 'usage is returned');
    like($res->{json}->{text}, qr!/zengin help!, 'usage contains help');
    like($res->{json}->{text}, qr!/zengin 0001!, 'usage contains examples');
};

done_testing;

sub slack_request {
    my ($app, $text, %opts) = @_;

    my $body = join '&',
        'command=' . uri_escape_utf8('/zengin'),
        'text=' . uri_escape_utf8($text),
        'team_id=T0001',
        'channel_id=C0001',
        'user_id=U0001';

    my $timestamp = $opts{timestamp} || time;
    my $signing_secret = $opts{signing_secret} || $ENV{SLACK_SIGNING_SECRET};
    my $signature = 'v0=' . hmac_sha256_hex("v0:$timestamp:$body", $signing_secret);
    $signature = 'v0=invalid' if $opts{invalid_signature};

    return request(
        $app,
        'POST',
        '/slack/zengin',
        body => $body,
        headers => {
            CONTENT_TYPE                   => 'application/x-www-form-urlencoded',
            CONTENT_LENGTH                 => length($body),
            HTTP_X_SLACK_REQUEST_TIMESTAMP => $timestamp,
            HTTP_X_SLACK_SIGNATURE         => $signature,
        },
    );
}

sub request {
    my ($app, $method, $path, %args) = @_;

    my $body = defined $args{body} ? $args{body} : q{};
    open my $input_fh, '<', \$body or die "Failed to open in-memory input: $!";

    my $env = {
        REQUEST_METHOD     => $method,
        PATH_INFO          => $path,
        QUERY_STRING       => $args{query_string} || q{},
        REQUEST_URI        => $path,
        SCRIPT_NAME        => q{},
        SERVER_NAME        => 'localhost',
        SERVER_PORT        => 5000,
        'psgi.version'     => [1, 1],
        'psgi.url_scheme'  => 'http',
        'psgi.input'       => $input_fh,
        'psgi.errors'      => *STDERR,
        'psgi.multithread' => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 0,
        'psgi.nonblocking'  => 0,
        %{ $args{headers} || {} },
    };

    my $res = $app->($env);
    my $response_body = join q{}, @{$res->[2]};
    my %headers = @{$res->[1]};

    my $decoded_json;
    if (($headers{'Content-Type'} || q{}) =~ m{\Aapplication/json\b}) {
        $decoded_json = decode_json($response_body);
    }

    return {
        status  => $res->[0],
        headers => \%headers,
        body    => $response_body,
        json    => $decoded_json,
    };
}

{
    package TestBackend;

    use strict;
    use warnings;

    sub new { bless {}, shift }

    sub meta {
        return {
            class    => 'Zengin::Pl',
            version  => '0.01',
            base_url => 'https://example.invalid/zengin-data',
            source   => {
                kind       => 'zengin-data-mirror',
                revision   => undef,
                updated_at => undef,
            },
        };
    }

    sub get_bank {
        my ($self, $bank_code) = @_;

        return if $bank_code ne '0001';

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
            return [] if $bank_term ne '0001';

            return [
                {
                    code => '777',
                    name => '東京都庁出張所',
                    hira => 'とうきょうとちょう',
                    kana => 'トウキョウトチョウ',
                    roma => 'toukyoutotyou',
                },
                {
                    code => '110',
                    name => '東京中央',
                    hira => 'とうきょうちゅうおう',
                    kana => 'トウキョウチュウオウ',
                    roma => 'toukyouchuuou',
                },
                {
                    code => '001',
                    name => '東京営業部',
                    hira => 'とうきよう',
                    kana => 'トウキヨウ',
                    roma => 'toukiyou',
                },
                {
                    code => '622',
                    name => '東京中央市場内出張所',
                    hira => 'とうきょうちゅうおうしじょうない',
                    kana => 'トウキョウチュウオウシジョウナイ',
                    roma => 'toukyouchuuousijounai',
                },
                {
                    code => '078',
                    name => '東京法人営業部',
                    hira => 'とうきようほうじん',
                    kana => 'トウキヨウホウジン',
                    roma => 'toukiyouhoujin',
                },
                {
                    code => '253',
                    name => '東京ファッションタウン出張所',
                    hira => 'とうきょうふぁっしょんたうん',
                    kana => 'トウキョウファッションタウン',
                    roma => 'toukyoufassyontown',
                },
            ] if $branch_term eq '東京';

            return [
                {
                    code => '520',
                    name => '横浜支店',
                    hira => 'よこはま',
                    kana => 'ヨコハマ',
                    roma => 'yokohama',
                },
                {
                    code => '510',
                    name => '横浜駅前支店',
                    hira => 'よこはまえきまえ',
                    kana => 'ヨコハマエキマエ',
                    roma => 'yokohamaekimae',
                },
            ] if $branch_term eq '横浜';

            return [];
        }

        return [] if $bank_term ne 'みずほ';

        return [
            {
                code => '4859',
                name => '埼玉みずほ農協',
                hira => 'さいたまみずほのうきょう',
                kana => 'サイタマミズホノウキョウ',
                roma => 'saitamamizuho',
            },
            {
                code => '0289',
                name => 'みずほ信託',
                hira => 'みずほしんたく',
                kana => 'ミズホシンタク',
                roma => 'mizuhoshintaku',
            },
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
