package Zengin::PL::API;

use strict;
use warnings;
use utf8;

use Digest::SHA qw(hmac_sha256_hex);
use Encode qw(decode_utf8);
use JSON::PP ();
use URI::Escape qw(uri_unescape);

sub new {
    my ($class, %args) = @_;

    return bless {
        backend       => $args{backend},
        backend_class => $args{backend_class} || $ENV{ZENGIN_PL_API_BACKEND_CLASS} || 'Zengin::Pl',
        json          => JSON::PP->new->utf8->canonical->allow_nonref,
    }, $class;
}

sub to_app {
    my ($self) = @_;

    return sub {
        my ($env) = @_;
        return $self->handle_request($env);
    };
}

sub handle_request {
    my ($self, $env) = @_;

    my $method = $env->{REQUEST_METHOD} || 'GET';
    my $path   = $env->{PATH_INFO}      || '/';

    if ($path =~ m{\A/slack/zengin/?\z}) {
        return $self->_handle_slack_zengin($env) if $method eq 'POST';

        return $self->_plain_response(405, 'Only POST is supported');
    }

    if ($method ne 'GET') {
        return $self->_json_response(405, {
            error => {
                code    => 'method_not_allowed',
                message => 'Only GET is supported',
            },
        });
    }

    if ($path =~ m{\A/api/meta/?\z}) {
        return $self->_handle_meta;
    }

    if ($path =~ m{\A/api/banks/(\d{4})/branches/(\d{3})/?\z}) {
        return $self->_handle_get_branch($1, $2);
    }

    if ($path =~ m{\A/api/banks/(\d{4})/branches/?\z}) {
        return $self->_handle_search_branches($1, $env);
    }

    if ($path =~ m{\A/api/banks/(\d{4})/?\z}) {
        return $self->_handle_get_bank($1);
    }

    if ($path =~ m{\A/api/banks/?\z}) {
        return $self->_handle_search_banks($env);
    }

    return $self->_json_response(404, {
        error => {
            code    => 'not_found',
            message => 'Route not found',
        },
    });
}

sub _handle_slack_zengin {
    my ($self, $env) = @_;

    my $raw_body = $self->_read_request_body($env);
    my $verification_error = $self->_verify_slack_request($env, $raw_body);
    return $verification_error if $verification_error;

    my $params = $self->_parse_query_string($raw_body);
    my $text   = defined $params->{text} ? $params->{text} : q{};

    my $message = eval { $self->_dispatch_slack_command($text) };
    if (my $error = $@) {
        warn "Slack command failed: $error";
        return $self->_slack_response('検索中にエラーが発生しました。時間をおいて再度お試しください。');
    }

    return $self->_slack_response($message);
}

sub _dispatch_slack_command {
    my ($self, $text) = @_;

    $text = q{} if !defined $text;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;

    my @tokens = grep { length $_ } split /\s+/, $text;
    return $self->_slack_usage if !@tokens || @tokens > 2;

    if (@tokens == 1) {
        return $self->_slack_lookup_bank($tokens[0]);
    }

    return $self->_slack_lookup_branch($tokens[0], $tokens[1]);
}

sub _slack_lookup_bank {
    my ($self, $bank_term) = @_;

    my ($bank, $message) = $self->_slack_resolve_bank($bank_term);
    return $message if !$bank;

    return $self->_format_slack_bank($bank);
}

sub _slack_lookup_branch {
    my ($self, $bank_term, $branch_term) = @_;

    my ($bank, $bank_message) = $self->_slack_resolve_bank($bank_term);
    return $bank_message if !$bank;

    if ($branch_term =~ /\A\d{3}\z/) {
        my ($branch, $branch_message) = $self->_slack_find_branch($bank->{code}, $branch_term);
        return $branch_message if !$branch;

        return $self->_format_slack_bank_and_branch($bank, $branch);
    }

    my ($branches, $branch_message) = $self->_slack_search_branches($bank, $branch_term);
    return $branch_message if !$branches;

    return $self->_format_slack_branch_list($bank, $branches);
}

sub _slack_resolve_bank {
    my ($self, $bank_term) = @_;

    if ($bank_term =~ /\A\d{4}\z/) {
        my ($bank, $error) = $self->_call_backend('get_bank', $bank_term);
        return (undef, $self->_slack_backend_error_message) if $error;
        return (undef, "銀行が見つかりません: $bank_term") if !$bank;

        return ($self->_normalize_bank($bank), undef);
    }

    my ($banks, $error) = $self->_call_backend('search', $bank_term);
    return (undef, $self->_slack_backend_error_message) if $error;

    $banks ||= [];
    my @banks = map { $self->_normalize_bank($_) } @{$banks};
    @banks = $self->_sort_banks_for_slack($bank_term, @banks);

    return (undef, "銀行が見つかりません: $bank_term") if !@banks;
    return ($banks[0], undef) if @banks == 1;

    return (undef, $self->_format_slack_bank_candidates(\@banks));
}

sub _slack_find_branch {
    my ($self, $bank_code, $branch_code) = @_;

    my ($branch, $error) = $self->_call_backend('get_branch', $bank_code, $branch_code);
    return (undef, $self->_slack_backend_error_message) if $error;
    return (undef, "支店が見つかりません: $bank_code/$branch_code") if !$branch;

    return ($self->_normalize_branch($branch), undef);
}

sub _slack_search_branches {
    my ($self, $bank, $branch_term) = @_;

    my ($branches, $error) = $self->_call_backend('search', $bank->{code}, $branch_term);
    return (undef, $self->_slack_backend_error_message) if $error;

    $branches ||= [];
    my @branches = map { $self->_slice_fields($_, qw(code name)) } @{$branches};
    @branches = $self->_sort_branches_for_slack(@branches);

    return (undef, "支店が見つかりません: $bank->{code} $branch_term") if !@branches;

    return (\@branches, undef);
}

sub _sort_banks_for_slack {
    my ($self, $term, @banks) = @_;

    return sort {
        $self->_slack_bank_match_rank($a, $term) <=> $self->_slack_bank_match_rank($b, $term)
            || (($a->{code} // q{}) cmp ($b->{code} // q{}))
            || (($a->{name} // q{}) cmp ($b->{name} // q{}))
    } @banks;
}

sub _slack_bank_match_rank {
    my ($self, $bank, $term) = @_;

    return 1 if !defined $term || $term eq q{};

    for my $field (qw(code name hira kana roma)) {
        next if !defined $bank->{$field};
        return 0 if $bank->{$field} eq $term;
    }

    return 1;
}

sub _sort_branches_for_slack {
    my ($self, @branches) = @_;

    return sort {
        (($a->{code} // q{}) cmp ($b->{code} // q{}))
            || (($a->{name} // q{}) cmp ($b->{name} // q{}))
    } @branches;
}

sub _verify_slack_request {
    my ($self, $env, $raw_body) = @_;

    my @secrets = $self->_slack_signing_secrets;
    return $self->_plain_response(500, 'SLACK_SIGNING_SECRET or SLACK_SIGNING_SECRETS is not configured')
        if !@secrets;

    my $timestamp = $env->{HTTP_X_SLACK_REQUEST_TIMESTAMP};
    my $signature = $env->{HTTP_X_SLACK_SIGNATURE};

    return $self->_plain_response(401, 'Missing Slack signature')
        if !defined $timestamp || !defined $signature;

    return $self->_plain_response(401, 'Invalid Slack timestamp')
        if $timestamp !~ /\A\d+\z/;

    return $self->_plain_response(401, 'Slack request timestamp is too old')
        if abs(time - $timestamp) > 60 * 5;

    my $base_string = join q{:}, 'v0', $timestamp, $raw_body;

    for my $secret (@secrets) {
        my $expected = 'v0=' . hmac_sha256_hex($base_string, $secret);
        return if $self->_secure_compare($signature, $expected);
    }

    return $self->_plain_response(401, 'Invalid Slack signature');
}

sub _slack_signing_secrets {
    my ($self) = @_;

    if (defined $ENV{SLACK_SIGNING_SECRETS} && $ENV{SLACK_SIGNING_SECRETS} ne q{}) {
        my @secrets = grep { length $_ } map {
            s/\A\s+//;
            s/\s+\z//;
            $_;
        } split /,/, $ENV{SLACK_SIGNING_SECRETS};

        return @secrets;
    }

    return () if !defined $ENV{SLACK_SIGNING_SECRET} || $ENV{SLACK_SIGNING_SECRET} eq q{};
    return ($ENV{SLACK_SIGNING_SECRET});
}

sub _secure_compare {
    my ($self, $left, $right) = @_;

    return if !defined $left || !defined $right;

    my $diff = length($left) ^ length($right);
    my $max = length($left) > length($right) ? length($left) : length($right);

    for my $i (0 .. $max - 1) {
        my $left_char  = $i < length($left)  ? substr($left,  $i, 1) : "\0";
        my $right_char = $i < length($right) ? substr($right, $i, 1) : "\0";

        $diff |= ord($left_char) ^ ord($right_char);
    }

    return $diff == 0;
}

sub _read_request_body {
    my ($self, $env) = @_;

    my $input = $env->{'psgi.input'};
    return q{} if !$input;

    my $length = $env->{CONTENT_LENGTH} || 0;
    return q{} if !$length;

    my $body = q{};
    my $read = read $input, $body, $length;
    die "Failed to read request body: $!" if !defined $read;

    return $body;
}

sub _slack_usage {
    return <<'USAGE';
使い方:
 /zengin 0001
 /zengin みずほ
 /zengin 0001 001
 /zengin みずほ 001
 /zengin 0001 東京
 /zengin みずほ 東京
USAGE
}

sub _format_slack_bank {
    my ($self, $bank) = @_;

    return join "\n",
        '============================',
        sprintf('銀行コード　　　　: %s', $bank->{code} // q{}),
        sprintf('銀行名　　　　　　: %s', $bank->{name} // q{}),
        sprintf('銀行名（ひらがな）: %s', $bank->{hira} // q{}),
        sprintf('銀行名（カタカナ）: %s', $bank->{kana} // q{}),
        sprintf('銀行名（ローマ字）: %s', $bank->{roma} // q{});
}

sub _format_slack_bank_and_branch {
    my ($self, $bank, $branch) = @_;

    return join "\n",
        $self->_format_slack_bank($bank),
        '============================',
        sprintf('支店コード　　　　: %s', $branch->{code} // q{}),
        sprintf('支店名　　　　　　: %s', $branch->{name} // q{}),
        sprintf('支店名（ひらがな）: %s', $branch->{hira} // q{}),
        sprintf('支店名（カタカナ）: %s', $branch->{kana} // q{}),
        sprintf('支店名（ローマ字）: %s', $branch->{roma} // q{});
}

sub _format_slack_branch_list {
    my ($self, $bank, $branches) = @_;

    my @lines = map {
        sprintf '%-4s  %s  %-3s  %s',
            $bank->{code} // q{},
            $bank->{name} // q{},
            $_->{code} // q{},
            $_->{name} // q{}
    } @{$branches};

    return "```\n" . join("\n", @lines) . "\n```";
}

sub _format_slack_bank_candidates {
    my ($self, $banks) = @_;

    my @lines = map {
        sprintf '%-4s  %s',
            $_->{code} // q{},
            $_->{name} // q{}
    } @{$banks};

    return "銀行候補:\n```\n" . join("\n", @lines) . "\n```";
}

sub _slack_backend_error_message {
    return '検索中にエラーが発生しました。時間をおいて再度お試しください。';
}

sub _handle_get_bank {
    my ($self, $bank_code) = @_;

    my ($bank, $error) = $self->_call_backend('get_bank', $bank_code);
    return $self->_backend_error_response($error) if $error;

    if (!$bank) {
        return $self->_json_response(404, {
            error => {
                code    => 'bank_not_found',
                message => "Bank not found: $bank_code",
            },
        });
    }

    return $self->_json_response(200, {
        bank => $self->_normalize_bank($bank),
    });
}

sub _handle_search_banks {
    my ($self, $env) = @_;

    my $params = $self->_parse_query_string($env->{QUERY_STRING} || q{});
    my $name   = $params->{name};

    if (!defined $name || $name eq q{}) {
        return $self->_json_response(400, {
            error => {
                code    => 'invalid_request',
                message => 'Query parameter "name" is required',
            },
        });
    }

    my ($banks, $error) = $self->_call_backend('search', $name);
    return $self->_backend_error_response($error) if $error;

    $banks ||= [];

    return $self->_json_response(200, {
        banks => [map { $self->_normalize_bank($_) } @{$banks}],
    });
}

sub _handle_get_branch {
    my ($self, $bank_code, $branch_code) = @_;

    my ($bank, $bank_error_response) = $self->_find_bank($bank_code);
    return $bank_error_response if $bank_error_response;

    my ($branch, $error) = $self->_call_backend('get_branch', $bank_code, $branch_code);
    return $self->_backend_error_response($error) if $error;

    if (!$branch) {
        return $self->_json_response(404, {
            error => {
                code    => 'branch_not_found',
                message => "Branch not found: $bank_code/$branch_code",
            },
        });
    }

    return $self->_json_response(200, {
        bank   => $self->_slice_fields($bank, qw(code name)),
        branch => $self->_normalize_branch($branch),
    });
}

sub _handle_search_branches {
    my ($self, $bank_code, $env) = @_;

    my ($bank, $bank_error_response) = $self->_find_bank($bank_code);
    return $bank_error_response if $bank_error_response;

    my $params = $self->_parse_query_string($env->{QUERY_STRING} || q{});
    my $name   = $params->{name};

    if (!defined $name || $name eq q{}) {
        return $self->_json_response(400, {
            error => {
                code    => 'invalid_request',
                message => 'Query parameter "name" is required',
            },
        });
    }

    my ($branches, $error) = $self->_call_backend('search', $bank_code, $name);
    return $self->_backend_error_response($error) if $error;

    $branches ||= [];

    return $self->_json_response(200, {
        bank     => $self->_slice_fields($bank, qw(code name)),
        branches => [map { $self->_slice_fields($_, qw(code name)) } @{$branches}],
    });
}

sub _handle_meta {
    my ($self) = @_;

    my $backend = $self->_backend;
    my $backend_meta = $self->_backend_meta($backend);

    return $self->_json_response(200, {
        api => {
            name       => defined $ENV{APP_NAME} ? $ENV{APP_NAME} : 'zengin-pl-api',
            version    => $self->_env_or_undef('APP_VERSION'),
            git_sha    => $self->_env_or_undef('APP_GIT_SHA'),
            build_time => $self->_env_or_undef('APP_BUILD_TIME'),
        },
        backend => {
            class    => $backend_meta->{class},
            version  => $backend_meta->{version},
            base_url => $backend_meta->{base_url},
        },
        data => {
            source => $backend_meta->{source},
        },
    });
}

sub _find_bank {
    my ($self, $bank_code) = @_;

    my ($bank, $error) = $self->_call_backend('get_bank', $bank_code);
    return (undef, $self->_backend_error_response($error)) if $error;

    if (!$bank) {
        return (undef, $self->_json_response(404, {
            error => {
                code    => 'bank_not_found',
                message => "Bank not found: $bank_code",
            },
        }));
    }

    return ($bank, undef);
}

sub _call_backend {
    my ($self, $method, @args) = @_;

    my $result = eval {
        my $backend = $self->_backend;
        die sprintf('Backend does not support %s', $method) unless $backend->can($method);
        return $backend->$method(@args);
    };

    return ($result, undef) if !$@;
    return (undef, $@);
}

sub _backend {
    my ($self) = @_;

    return $self->{backend} if $self->{backend};

    my $backend_class = $self->{backend_class};
    eval "require ${backend_class}; 1"
        or die "Failed to load backend ${backend_class}: $@";

    $self->{backend} = $backend_class->can('new')
        ? $backend_class->new
        : $backend_class;

    return $self->{backend};
}

sub _backend_meta {
    my ($self, $backend) = @_;

    if (defined $backend && ref $backend && $backend->can('meta')) {
        my $meta = $backend->meta;
        return $meta if ref $meta eq 'HASH';
    }

    return {
        class    => $self->{backend_class},
        version  => undef,
        base_url => undef,
        source   => {
            kind       => undef,
            revision   => undef,
            updated_at => undef,
        },
    };
}

sub _parse_query_string {
    my ($self, $query_string) = @_;

    my %params;
    for my $pair (grep { length $_ } split /[&;]/, $query_string) {
        my ($key, $value) = split /=/, $pair, 2;
        next if !defined $key || $key eq q{};

        $key   =~ tr/+/ /;
        $value = defined $value ? $value : q{};
        $value =~ tr/+/ /;

        $key   = decode_utf8(uri_unescape($key));
        $value = decode_utf8(uri_unescape($value));

        $params{$key} = $value;
    }

    return \%params;
}

sub _normalize_bank {
    my ($self, $bank) = @_;

    return undef if !defined $bank;

    if (ref $bank eq 'HASH') {
        return { %{$bank} };
    }

    if (ref $bank && $bank->can('TO_JSON')) {
        return $bank->TO_JSON;
    }

    my %normalized;
    for my $field (qw(code name hira kana roma)) {
        next if !ref $bank || !$bank->can($field);
        my $value = $bank->$field;
        $normalized{$field} = $value if defined $value;
    }

    return \%normalized if %normalized;
    return $bank;
}

sub _normalize_branch {
    my ($self, $branch) = @_;

    return $self->_normalize_bank($branch);
}

sub _slice_fields {
    my ($self, $entity, @fields) = @_;

    my $normalized = ref $entity eq 'HASH'
        ? $entity
        : $self->_normalize_bank($entity);

    my %sliced;
    for my $field (@fields) {
        $sliced{$field} = $normalized->{$field}
            if ref $normalized eq 'HASH' && exists $normalized->{$field};
    }

    return \%sliced;
}

sub _env_or_undef {
    my ($self, $name) = @_;
    return defined $ENV{$name} && $ENV{$name} ne q{} ? $ENV{$name} : undef;
}

sub _backend_error_response {
    my ($self, $error) = @_;

    chomp $error;

    return $self->_json_response(500, {
        error => {
            code    => 'backend_error',
            message => $error,
        },
    });
}

sub _json_response {
    my ($self, $status, $payload) = @_;

    my $body = $self->{json}->encode($payload);

    return [
        $status,
        [
            'Content-Type'   => 'application/json; charset=utf-8',
            'Content-Length' => length $body,
        ],
        [$body],
    ];
}

sub _slack_response {
    my ($self, $text) = @_;

    return $self->_json_response(200, {
        response_type => 'ephemeral',
        text          => $text,
    });
}

sub _plain_response {
    my ($self, $status, $body) = @_;

    return [
        $status,
        [
            'Content-Type'   => 'text/plain; charset=utf-8',
            'Content-Length' => length $body,
        ],
        [$body],
    ];
}

1;
