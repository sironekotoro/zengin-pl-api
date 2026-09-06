use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use Encode qw(decode_utf8);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Test::More;

my $repo_root = dirname(dirname(File::Spec->rel2abs(__FILE__)));
my $script    = File::Spec->catfile($repo_root, 'bin', 'sync-zengin-pl-ref.sh');

plan skip_all => 'bash is not available' unless _find_in_path('bash');
plan skip_all => 'jq is not available'   unless _find_in_path('jq');
plan skip_all => 'git is not available'  unless _find_in_path('git');

subtest 'validate_sha_format accepts only 40-char lowercase hex' => sub {
    my $good = '0123456789abcdef0123456789abcdef01234567';

    ok(_source_and_run("validate_sha_format '$good'"), 'a well-formed sha is accepted');
    ok(!_source_and_run(q{validate_sha_format 'ABCDEF0123456789abcdef0123456789abcdef01'}), 'uppercase hex is rejected');
    ok(!_source_and_run(q{validate_sha_format 'abc'}), 'a short string is rejected');
    ok(
        !_source_and_run(q{validate_sha_format '0123456789abcdef0123456789abcdef0123456; rm -rf /'}),
        'a shell-metacharacter payload is rejected outright',
    );
};

subtest 'short_sha / branch_name / commit_message / pr_title are pure and stable' => sub {
    my $sha = '0123456789abcdef0123456789abcdef01234567';

    is(_source_and_capture("short_sha '$sha'"), '0123456789ab', 'short_sha takes the first 12 chars');
    is(_source_and_capture('branch_name'), 'chore/update-zengin-pl', 'branch_name is the fixed reusable branch');
    is(
        _source_and_capture("commit_message '$sha'"),
        'chore: update zengin-pl pin to 0123456789ab',
        'commit_message matches the documented format',
    );
    is(
        _source_and_capture("pr_title '$sha'"),
        'Update zengin-pl to 0123456789ab',
        'pr_title matches the documented format',
    );
};

subtest 'pr_body includes old/new SHA and the source run URL' => sub {
    my $body = _source_and_capture(
        "pr_body 'oldsha0000000000000000000000000000000001' 'newsha0000000000000000000000000000000002' 'https://example.invalid/run/1'"
    );

    like($body, qr/oldsha0000000000000000000000000000000001/, 'old SHA is present');
    like($body, qr/newsha0000000000000000000000000000000002/, 'new SHA is present');
    like($body, qr{https://github\.com/sironekotoro/zengin-pl/commit/newsha0+2}, 'zengin-pl commit URL is present');
    like($body, qr{https://example\.invalid/run/1}, 'source workflow run URL is present');
    like($body, qr/自動生成PR/, 'the PR states that it is auto-generated');
    like($body, qr/deploy/, 'the PR mentions that merging triggers the normal deploy');
};

subtest 'write_ref_if_changed detects no-op vs. real changes' => sub {
    my ($fh, $ref_file) = tempfile();
    print {$fh} "oldsha0000000000000000000000000000000001\n";
    close $fh;

    ok(
        !_source_and_run("write_ref_if_changed '$ref_file' 'oldsha0000000000000000000000000000000001'"),
        'the same SHA is reported as a no-op (non-zero exit)',
    );
    is(_slurp($ref_file), "oldsha0000000000000000000000000000000001\n", 'the file is left untouched');

    ok(
        _source_and_run("write_ref_if_changed '$ref_file' 'newsha0000000000000000000000000000000002'"),
        'a different SHA is reported as a change (zero exit)',
    );
    is(_slurp($ref_file), "newsha0000000000000000000000000000000002\n", 'the file is rewritten to exactly one line');
};

subtest 'commit_exists / is_ancestor_of_master use real git against a local fixture' => sub {
    my $dir = tempdir(CLEANUP => 1);
    _run_git($dir, qw(init -q));
    _run_git($dir, qw(config user.email t@example.invalid));
    _run_git($dir, qw(config user.name  t));

    _write($dir, 'f', "a\n");
    _run_git($dir, qw(add f));
    _run_git($dir, qw(commit -q -m c1));
    my $c1 = _run_git($dir, qw(rev-parse HEAD));

    _write($dir, 'f', "b\n");
    _run_git($dir, qw(add f));
    _run_git($dir, qw(commit -q -m c2));
    my $c2 = _run_git($dir, qw(rev-parse HEAD));

    _run_git($dir, qw(branch -m master));
    _run_git($dir, 'checkout', '-q', '-b', 'feature', $c1);
    _write($dir, 'f', "c\n");
    _run_git($dir, qw(add f));
    _run_git($dir, qw(commit -q -m side));
    my $side = _run_git($dir, qw(rev-parse HEAD));

    _run_git($dir, qw(checkout -q master));
    _run_git($dir, qw(remote add origin .));
    _run_git($dir, qw(fetch -q origin));

    ok(_source_and_run("commit_exists '$dir' '$c2'"), 'a real commit is found');
    ok(
        !_source_and_run("commit_exists '$dir' 'deadbeef00000000000000000000000000000099'"),
        'a nonexistent SHA is rejected',
    );
    ok(_source_and_run("is_ancestor_of_master '$dir' '$c1'"), 'a commit on master history is accepted');
    ok(
        !_source_and_run("is_ancestor_of_master '$dir' '$side'"),
        'a commit only reachable from a side branch is rejected',
    );
};

subtest 'check_runs_all_success requires the Perl matrix to be fully green' => sub {
    local $ENV{PATH} = _mock_gh_path() . ':' . $ENV{PATH};

    {
        local $ENV{GH_MOCK_MODE} = 'all_success';
        ok(_source_and_run("check_runs_all_success deadbeef"), 'a fully successful matrix passes');
    }
    {
        local $ENV{GH_MOCK_MODE} = 'one_failed';
        ok(!_source_and_run("check_runs_all_success deadbeef"), 'one failing job in the matrix is rejected');
    }
    {
        local $ENV{GH_MOCK_MODE} = 'none';
        ok(!_source_and_run("check_runs_all_success deadbeef"), 'no matching check-runs at all is treated as unverified');
    }
};

subtest 'ensure_update_pr creates once, then reuses the same PR' => sub {
    local $ENV{PATH} = _mock_gh_path() . ':' . $ENV{PATH};
    my ($body_fh, $body_file) = tempfile();
    print {$body_fh} "body\n";
    close $body_fh;

    {
        my ($log_fh, $log) = tempfile();
        close $log_fh;
        local $ENV{GH_MOCK_PR_LIST} = '[]';
        local $ENV{GH_CALL_LOG}     = $log;
        _source_and_run("ensure_update_pr chore/update-zengin-pl 'Update zengin-pl to abc123' '$body_file'");
        like(_slurp($log), qr/PR_CREATE_CALLED/, 'no existing open PR: a new PR is created');
        unlike(_slurp($log), qr/PR_EDIT_CALLED/, 'gh pr edit is not called when creating');
    }

    {
        my ($log_fh, $log) = tempfile();
        close $log_fh;
        local $ENV{GH_MOCK_PR_LIST} = '[{"number":42}]';
        local $ENV{GH_CALL_LOG}     = $log;
        _source_and_run("ensure_update_pr chore/update-zengin-pl 'Update zengin-pl to abc123' '$body_file'");
        like(_slurp($log), qr/PR_EDIT_CALLED/, 'an existing open PR is edited in place');
        unlike(_slurp($log), qr/PR_CREATE_CALLED/, 'gh pr create is not called when one already exists');
    }
};

done_testing;

sub _find_in_path {
    my ($bin) = @_;
    for my $dir (split /:/, $ENV{PATH} || q{}) {
        return 1 if -x "$dir/$bin";
    }
    return 0;
}

# sourceして式を評価し、終了コードを真偽値として返す(0終了=真)。
sub _source_and_run {
    my ($expr) = @_;
    system("bash", "-c", "source '$script' >/dev/null 2>&1; $expr");
    return $? == 0;
}

# sourceして式の標準出力を1行取得する。
sub _source_and_capture {
    my ($expr) = @_;
    my $out = decode_utf8(`bash -c "source '$script' >/dev/null 2>&1; $expr"`);
    $out =~ s/\n\z//;
    return $out;
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _write {
    my ($dir, $name, $content) = @_;
    open my $fh, '>', File::Spec->catfile($dir, $name) or die $!;
    print {$fh} $content;
    close $fh;
}

sub _run_git {
    my ($dir, @args) = @_;
    my $out = `git -C '$dir' @args`;
    die "git @args failed" if $? != 0;
    $out =~ s/\n\z//;
    return $out;
}

# --jq FILTER を実際にjqへ適用する簡易ghモック。api/pr list/pr create/pr edit
# だけを理解する。sync-zengin-pl-ref.shがgh経由で読む形をそのまま再現し、
# ネットワークなしでcheck_runs_all_success/ensure_update_prを検証する。
sub _mock_gh_path {
    my $dir = tempdir(CLEANUP => 1);
    my $gh  = File::Spec->catfile($dir, 'gh');

    open my $fh, '>', $gh or die $!;
    print {$fh} <<'MOCK';
#!/usr/bin/env bash
filter=
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--jq" ]]; then
    filter="${args[$((i+1))]}"
  fi
done

json=
if [[ "$1" == "api" ]]; then
  case "$GH_MOCK_MODE" in
    all_success)
      json='{"check_runs":[{"name":"Perl 5.36","status":"completed","conclusion":"success","html_url":"https://example.invalid/run1"},{"name":"Perl 5.42","status":"completed","conclusion":"success","html_url":"https://example.invalid/run2"}]}'
      ;;
    one_failed)
      json='{"check_runs":[{"name":"Perl 5.36","status":"completed","conclusion":"success"},{"name":"Perl 5.42","status":"completed","conclusion":"failure"}]}'
      ;;
    none)
      json='{"check_runs":[{"name":"docker","status":"completed","conclusion":"success"}]}'
      ;;
  esac
elif [[ "$1" == "pr" && "$2" == "list" ]]; then
  json="$GH_MOCK_PR_LIST"
elif [[ "$1" == "pr" && "$2" == "create" ]]; then
  echo "PR_CREATE_CALLED $*" >> "$GH_CALL_LOG"
  exit 0
elif [[ "$1" == "pr" && "$2" == "edit" ]]; then
  echo "PR_EDIT_CALLED $*" >> "$GH_CALL_LOG"
  exit 0
else
  echo "unhandled mock gh call: $*" >&2
  exit 1
fi

if [[ -n "$filter" ]]; then
  jq "$filter" <<<"$json"
else
  printf '%s\n' "$json"
fi
MOCK
    close $fh;
    chmod 0755, $gh;

    return $dir;
}
