use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Test::More;

my $repo_root = dirname(dirname(File::Spec->rel2abs(__FILE__)));
my $script    = File::Spec->catfile($repo_root, 'bin', 'auto-merge-zengin-pl-pr.sh');

plan skip_all => 'bash is not available' unless _find_in_path('bash');
plan skip_all => 'jq is not available'   unless _find_in_path('jq');

my $OLD_SHA = '2339d6757c57e4365b0c8bf1017b9a4608c4d7eb';
my $NEW_SHA = 'c14b2a7be090d6a54ef445947f09867c7a9cca05';
my $HEAD_SHA = 'b' x 40;
my $BASE_SHA = 'a' x 40;

my $VALID_DIFF = <<"DIFF";
diff --git a/zengin-pl.ref b/zengin-pl.ref
index abc..def 100644
--- a/zengin-pl.ref
+++ b/zengin-pl.ref
\@\@ -1 +1 \@\@
-${OLD_SHA}
+${NEW_SHA}
DIFF

subtest 'parse_pin_diff accepts only an exact single-line SHA replacement' => sub {
    ok(_source_and_run(qq{parse_pin_diff "\$(cat <<'EOF'\n$VALID_DIFF\nEOF\n)"}), 'a clean pin-only diff is accepted');

    my $two_files = $VALID_DIFF . <<'EOF';
diff --git a/README.md b/README.md
index 111..222 100644
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-old
+new
EOF
    ok(!_source_and_run(qq{parse_pin_diff "\$(cat <<'EOF2'\n$two_files\nEOF2\n)"}), 'a second changed file is rejected');

    my $wrong_file = $VALID_DIFF;
    $wrong_file =~ s/zengin-pl\.ref/other.txt/g;
    ok(!_source_and_run(qq{parse_pin_diff "\$(cat <<'EOF3'\n$wrong_file\nEOF3\n)"}), 'a diff touching a different file is rejected');

    my $extra_lines = <<"EOF4";
diff --git a/zengin-pl.ref b/zengin-pl.ref
index abc..def 100644
--- a/zengin-pl.ref
+++ b/zengin-pl.ref
\@\@ -1,2 +1,2 \@\@
-${OLD_SHA}
-extra old line
+${NEW_SHA}
+extra new line
EOF4
    ok(!_source_and_run(qq{parse_pin_diff "\$(cat <<'EOF5'\n$extra_lines\nEOF5\n)"}), 'extra changed lines beyond the SHA are rejected');

    my $non_hex = $VALID_DIFF;
    $non_hex =~ s/-\Q$OLD_SHA\E/-not-a-real-sha-at-all-not-a-real-sha-at-all-x/;
    ok(!_source_and_run(qq{parse_pin_diff "\$(cat <<'EOF6'\n$non_hex\nEOF6\n)"}), 'a non-hex "SHA" is rejected');
};

subtest 'parse_pin_diff rejects hidden extra changes and mode changes' => sub {
    ok(_source_and_run("parse_pin_diff " . _shell_single_quote($VALID_DIFF)), 'control: identical invocation accepts valid diff with final LF');
    my @bad = (
        $VALID_DIFF . "+\n",
        $VALID_DIFF . "-\n",
        $VALID_DIFF . "+ +hidden\n",
        $VALID_DIFF . "++hidden\n",
        $VALID_DIFF . "--hidden\n",
        $VALID_DIFF . "\\ No newline at end of file\n",
        $VALID_DIFF . "\@\@ -3 +3 \@\@\n-old\n+new\n",
    );
    (my $mode = $VALID_DIFF) =~ s/100644/100755/;
    push @bad, $mode;
    (my $context = $VALID_DIFF) =~ s/\@\@ -1 \+1 \@\@/\@\@ -1,2 +1,2 \@\@\n context/;
    push @bad, $context;
    for my $diff (@bad) {
        ok(!_source_and_run("parse_pin_diff " . _shell_single_quote($diff)), 'unexpected diff record rejected');
    }
};

subtest 'no_blocking_reviews requires known nonblocking review states' => sub {
    ok(_source_and_run(q{no_blocking_reviews '[]'}), 'no reviews at all is fine');
    for my $bad ('null', '{}', 'invalid json', '[{}]', '[{"state":"UNKNOWN"}]') {
        ok(!_source_and_run('no_blocking_reviews ' . _shell_single_quote($bad)), 'missing or malformed reviews block');
    }
    ok(_source_and_run(q{no_blocking_reviews '[{"state":"APPROVED"}]'}), 'an approval is fine');
    ok(
        !_source_and_run(q{no_blocking_reviews '[{"state":"APPROVED"},{"state":"CHANGES_REQUESTED"}]'}),
        'any CHANGES_REQUESTED review blocks, even alongside an approval',
    );
};

# main() 全体のシナリオを、gh/jqをmockして検証する。
# それぞれ「どの条件で弾かれるか」を確認するのが目的。
subtest 'main(): full scenarios via a scripted gh mock' => sub {
    my $base_pr_view = {
        author       => { login => 'app/github-actions' },
        baseRefName  => 'main',
        baseRefOid   => $BASE_SHA,
        isCrossRepository => \0,
        headRefName  => 'chore/update-zengin-pl',
        headRefOid   => $HEAD_SHA,
        isDraft      => \0,
        files        => [ { path => 'zengin-pl.ref' } ],
        mergeable    => 'MERGEABLE',
        reviews      => [],
    };

    subtest 'no open PR: quiet no-op' => sub {
        my $r = _run_main(pr_list => '[]');
        is($r->{exit}, 0, 'exits 0');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'a fully valid PR is merged with the exact head SHA' => sub {
        my $r = _run_main(
            pr_list  => '[{"number":11}]',
            pr_view  => $base_pr_view,
            pr_diff  => $VALID_DIFF,
            zengin_pl_checkruns => _checkruns_json(['Perl 5.36', 'Perl 5.38', 'Perl 5.40', 'Perl 5.42']),
            api_checkruns       => _checkruns_json(['test', 'docker']),
            graphql  => _threads_json([]),
        );
        is($r->{exit}, 0, 'exits 0');
        like($r->{log}, qr/MERGE_CALLED.*pulls\/11\/merge.*sha=\Q$HEAD_SHA\E/, 'merges PR 11 pinned to the validated head SHA');
        is($r->{output}, 'merged_sha=' . ('a' x 40) . "\n", 'confirmed merge SHA is published to downstream job');
    };

    for my $result ('{"merged":false,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}', '{"merged":true}', '{"merged":true,"sha":"bad"}', 'not json', '') {
        my $r = _run_main(pr_list=>'[{"number":11}]', pr_view=>$base_pr_view, pr_diff=>$VALID_DIFF,
            zengin_pl_checkruns=>_checkruns_json(['Perl 5.36','Perl 5.38','Perl 5.40','Perl 5.42']),
            api_checkruns=>_checkruns_json(['test','docker']), merge_result=>$result);
        like($r->{log}, qr/MERGE_CALLED/, 'negative response fixture reaches merge API');
        isnt($r->{exit}, 0, 'unconfirmed/malformed merge response fails');
        is($r->{output}, '', 'no downstream deployment SHA emitted');
    }

    for my $case (
        ['base pin mismatch', 'override_pin_at_sha', "echo '" . ('c' x 40) . "'", qr/base pin bytes do not match/],
        ['head pin error with plausible output', 'override_pin_at_sha', "if [[ \"\$1\" == '$BASE_SHA' ]]; then echo '$OLD_SHA'; else echo '$NEW_SHA'; return 1; fi", qr/head pin bytes do not match/],
        ['head pin malformed', 'override_pin_at_sha', "if [[ \"\$1\" == '$BASE_SHA' ]]; then echo '$OLD_SHA'; else return 1; fi", qr/head pin bytes do not match/],
        ['base API error with plausible output', 'override_current_base_sha', "echo '$BASE_SHA'; return 1", qr/could not read current base SHA/],
        ['branch behind main', 'override_head_contains_base', 'return 1', qr/PR branch is behind main/],
    ) {
        subtest $case->[0] => sub {
            my $r = _run_main(pr_list=>'[{"number":11}]', pr_view=>$base_pr_view, pr_diff=>$VALID_DIFF, $case->[1]=>$case->[2]);
            like($r->{out}, $case->[3], 'stops for the intended reason');
            unlike($r->{log}, qr/MERGE_CALLED/, 'does not merge');
        };
    }
    subtest 'main advances after CI validation' => sub {
        my $marker = tempdir(CLEANUP=>1) . '/base-read';
        my $override = "if [[ -f '$marker' ]]; then echo '" . ('c' x 40) . "'; else touch '$marker'; echo '$BASE_SHA'; fi";
        my $r = _run_main(pr_list=>'[{"number":11}]', pr_view=>$base_pr_view, pr_diff=>$VALID_DIFF,
            zengin_pl_checkruns=>_checkruns_json(['Perl 5.36','Perl 5.38','Perl 5.40','Perl 5.42']),
            api_checkruns=>_checkruns_json(['test','docker']), override_current_base_sha=>$override);
        is($r->{exit}, 0, 'safe stop');
        like($r->{out}, qr/main changed during validation/, 'reaches final base freshness check');
        unlike($r->{log}, qr/MERGE_CALLED/, 'does not merge');
    };

    subtest 'unexpected author is rejected hard (exit 1)' => sub {
        my %pr_view = %$base_pr_view;
        $pr_view{author} = { login => 'someone-else' };
        my $r = _run_main(
            pr_list => '[{"number":11}]',
            pr_view => \%pr_view,
            pr_diff => $VALID_DIFF,
        );
        is($r->{exit}, 1, 'exits 1 (structurally unexpected)');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'unexpected head branch is rejected hard' => sub {
        my %pr_view = %$base_pr_view;
        $pr_view{headRefName} = 'some-other-branch';
        my $r = _run_main(pr_list => '[{"number":11}]', pr_view => \%pr_view, pr_diff => $VALID_DIFF);
        is($r->{exit}, 1, 'exits 1');
    };

    subtest 'unexpected base branch is rejected hard' => sub {
        my %pr_view = %$base_pr_view;
        $pr_view{baseRefName} = 'develop';
        my $r = _run_main(pr_list => '[{"number":11}]', pr_view => \%pr_view, pr_diff => $VALID_DIFF);
        is($r->{exit}, 1, 'exits 1');
    };

    subtest 'two changed files are rejected hard' => sub {
        my %pr_view = %$base_pr_view;
        $pr_view{files} = [ { path => 'zengin-pl.ref' }, { path => 'README.md' } ];
        my $r = _run_main(pr_list => '[{"number":11}]', pr_view => \%pr_view, pr_diff => $VALID_DIFF);
        is($r->{exit}, 1, 'exits 1');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'a changed file other than zengin-pl.ref is rejected hard' => sub {
        my %pr_view = %$base_pr_view;
        $pr_view{files} = [ { path => 'lib/Zengin/PL/API.pm' } ];
        my $r = _run_main(pr_list => '[{"number":11}]', pr_view => \%pr_view, pr_diff => $VALID_DIFF);
        is($r->{exit}, 1, 'exits 1');
    };

    subtest 'a malformed SHA in the diff is rejected hard' => sub {
        (my $bad_diff = $VALID_DIFF) =~ s/-\Q$OLD_SHA\E/-not-a-sha/;
        my $r = _run_main(pr_list => '[{"number":11}]', pr_view => $base_pr_view, pr_diff => $bad_diff);
        is($r->{exit}, 1, 'exits 1');
    };

    subtest 'new SHA not on zengin-pl master is rejected hard' => sub {
        my $r = _run_main(
            pr_list => '[{"number":11}]',
            pr_view => $base_pr_view,
            pr_diff => $VALID_DIFF,
            zengin_pl_checkruns => _checkruns_json(['Perl 5.36', 'Perl 5.38', 'Perl 5.40', 'Perl 5.42']),
            override_is_ancestor => 'return 1',
        );
        is($r->{exit}, 1, 'exits 1 (re-verification failed)');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'zengin-pl CI incomplete is rejected hard (re-verification)' => sub {
        my $r = _run_main(
            pr_list => '[{"number":11}]',
            pr_view => $base_pr_view,
            pr_diff => $VALID_DIFF,
            zengin_pl_checkruns => _checkruns_json_with([{ name => 'Perl 5.36', status => 'completed', conclusion => 'failure' }]),
        );
        is($r->{exit}, 1, 'exits 1');
    };

    subtest 'zengin-pl-api CI incomplete is a soft reject (exit 0, retry later)' => sub {
        my $r = _run_main(
            pr_list => '[{"number":11}]',
            pr_view => $base_pr_view,
            pr_diff => $VALID_DIFF,
            zengin_pl_checkruns => _checkruns_json(['Perl 5.36', 'Perl 5.38', 'Perl 5.40', 'Perl 5.42']),
            api_checkruns       => _checkruns_json_with([{ name => 'test', status => 'in_progress', conclusion => JSON_NULL() }]),
        );
        is($r->{exit}, 0, 'exits 0 (transient, not structurally broken)');
        like($r->{out}, qr/zengin-pl-api CI is not fully green/, 'reaches API CI rejection');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'no zengin-pl-api check-runs at all is a soft reject' => sub {
        my $r = _run_main(
            pr_list => '[{"number":11}]',
            pr_view => $base_pr_view,
            pr_diff => $VALID_DIFF,
            zengin_pl_checkruns => _checkruns_json(['Perl 5.36', 'Perl 5.38', 'Perl 5.40', 'Perl 5.42']),
            api_checkruns       => _checkruns_json([]),
        );
        is($r->{exit}, 0, 'exits 0');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'a merge conflict (mergeable != MERGEABLE) is a soft reject' => sub {
        my %pr_view = %$base_pr_view;
        $pr_view{mergeable} = 'CONFLICTING';
        my $r = _run_main(
            pr_list => '[{"number":11}]',
            pr_view => \%pr_view,
            pr_diff => $VALID_DIFF,
        );
        is($r->{exit}, 0, 'exits 0 (may resolve itself later)');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'a requested-changes review is a soft reject' => sub {
        my %pr_view = %$base_pr_view;
        $pr_view{reviews} = [ { state => 'CHANGES_REQUESTED' } ];
        my $r = _run_main(pr_list => '[{"number":11}]', pr_view => \%pr_view, pr_diff => $VALID_DIFF);
        is($r->{exit}, 0, 'exits 0');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'an unresolved review thread is a soft reject' => sub {
        my $r = _run_main(
            pr_list => '[{"number":11}]',
            pr_view => $base_pr_view,
            pr_diff => $VALID_DIFF,
            zengin_pl_checkruns => _checkruns_json(['Perl 5.36', 'Perl 5.38', 'Perl 5.40', 'Perl 5.42']),
            api_checkruns       => _checkruns_json(['test', 'docker']),
            graphql             => _threads_json([0]),
        );
        is($r->{exit}, 0, 'exits 0');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called');
    };

    subtest 'PR head changing mid-validation aborts the merge (soft reject)' => sub {
        my $r = _run_main(
            pr_list  => '[{"number":11}]',
            pr_view  => $base_pr_view,
            pr_diff  => $VALID_DIFF,
            zengin_pl_checkruns => _checkruns_json(['Perl 5.36', 'Perl 5.38', 'Perl 5.40', 'Perl 5.42']),
            api_checkruns       => _checkruns_json(['test', 'docker']),
            graphql             => _threads_json([]),
            override_current_head_sha => 'echo "a-different-sha-than-before-0000000001"',
        );
        is($r->{exit}, 0, 'exits 0 (will re-evaluate on the next run)');
        like($r->{out}, qr/PR head changed during validation/, 'reaches head-race rejection');
        unlike($r->{log}, qr/MERGE_CALLED/, 'merge is never called for a stale head');
    };
};

done_testing;

sub JSON_NULL { return undef }

sub _checkruns_json {
    my ($names) = @_;
    my @runs = map { +{ name => $_, status => 'completed', conclusion => 'success' } } @{$names};
    return _checkruns_json_with(\@runs);
}

sub _checkruns_json_with {
    my ($runs) = @_;
    require JSON::PP;
    return JSON::PP->new->canonical->encode({ check_runs => $runs });
}

sub _threads_json {
    my ($unresolved_indices) = @_;
    require JSON::PP;
    my %unresolved = map { $_ => 1 } @{$unresolved_indices};
    my @nodes = map { +{ isResolved => $unresolved{$_} ? JSON::PP::false() : JSON::PP::true() } } 0 .. 2;
    return JSON::PP->new->canonical->encode([{
        data => { repository => { pullRequest => { reviewThreads => { nodes => \@nodes, pageInfo => { hasNextPage => JSON::PP::false() } } } } },
    }]);
}

sub _find_in_path {
    my ($bin) = @_;
    for my $dir (split /:/, $ENV{PATH} || q{}) {
        return 1 if -x "$dir/$bin";
    }
    return 0;
}

sub _source_and_run {
    my ($expr) = @_;
    system("bash", "-c", "source '$script' >/dev/null 2>&1; $expr");
    return $? == 0;
}

# main() を、gh(モック)+ zengin-pl clone/検証をoverrideした状態で実行し、
# 終了コードとgh呼び出しログを返す。
sub _run_main {
    my (%args) = @_;
    require JSON::PP;

    my $mock_dir = _mock_gh_dir(
        pr_list             => $args{pr_list}  // '[]',
        pr_view             => defined $args{pr_view} ? JSON::PP->new->canonical->encode($args{pr_view}) : '{}',
        pr_diff             => $args{pr_diff}  // q{},
        graphql             => $args{graphql}  // _threads_json([]),
        zengin_pl_checkruns => $args{zengin_pl_checkruns} // _checkruns_json([]),
        api_checkruns       => $args{api_checkruns}       // _checkruns_json([]),
        merge_result => $args{merge_result} // '{"merged":true,"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}',
    );

    my ($log_fh, $log_file) = tempfile();
    close $log_fh;
    my ($output_fh, $output_file) = tempfile();
    close $output_fh;

    my $override_is_ancestor      = $args{override_is_ancestor}      // 'return 0';
    my $override_current_head_sha = $args{override_current_head_sha};

    my $base_override = $args{override_current_base_sha} // "echo '$BASE_SHA'";
    my $contains_override = $args{override_head_contains_base} // 'return 0';
    my $pin_override = $args{override_pin_at_sha} // "if [[ \"\$1\" == '$BASE_SHA' ]]; then echo '$OLD_SHA'; else echo '$NEW_SHA'; fi";
    my $overrides = "current_base_sha() { $base_override; }\n"
        . "head_contains_base() { $contains_override; }\n"
        . "pin_at_sha() { $pin_override; }\n"
        . "clone_zengin_pl() { mkdir -p \"\$1\"; }\n"
        . "commit_exists() { return 0; }\n"
        . "is_ancestor_of_master() { $override_is_ancestor; }\n";
    $overrides .= "current_head_sha() { $override_current_head_sha; }\n" if $override_current_head_sha;

    # quotemeta()はPerlの正規表現エスケープ用であり、改行を「バックスラッシュ+
    # 改行」に変換してしまう。bashはそれを行継続として解釈し、複数行の
    # $overridesが1行に溶接されて構文エラーになる。シェルへ渡す文字列は
    # 必ず_shell_single_quote()(単一引用符での正しいエスケープ)を使う。
    my $cmd = sprintf(
        'PATH=%s:$PATH GH_CALL_LOG=%s GITHUB_OUTPUT=%s bash -c %s',
        _shell_single_quote($mock_dir),
        _shell_single_quote($log_file),
        _shell_single_quote($output_file),
        _shell_single_quote("source '$script' >/dev/null 2>&1; $overrides main"),
    );

    my $out = `$cmd 2>&1`;
    my $exit = $? >> 8;

    return {
        exit => $exit,
        out  => $out,
        log  => _slurp($log_file),
        output => _slurp($output_file),
    };
}

sub _slurp {
    my ($path) = @_;
    return q{} unless -f $path;
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh> // q{};
}

# gh CLIの簡易mock。api/pr view/pr diff/pr list/graphql/mergeを理解し、
# --jqが渡された場合は実際のjqへ -r (gh実物と同じ: scalarはraw, 配列/objはJSON)
# で通す。
sub _mock_gh_dir {
    my (%data) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $gh  = File::Spec->catfile($dir, 'gh');

    my $pr_diff_file = File::Spec->catfile($dir, 'pr_diff.txt');
    open my $dfh, '>', $pr_diff_file or die $!;
    print {$dfh} $data{pr_diff};
    close $dfh;

    my %json_for = (
        PR_LIST      => $data{pr_list},
        PR_VIEW      => $data{pr_view},
        GRAPHQL      => $data{graphql},
        ZENGINPL_CHECKRUNS => $data{zengin_pl_checkruns},
        API_CHECKRUNS      => $data{api_checkruns},
    );

    open my $fh, '>', $gh or die $!;
    print {$fh} <<'MOCK_HEADER';
#!/usr/bin/env bash
filter=
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--jq" ]]; then filter="${args[$((i+1))]}"; fi
done
json=
MOCK_HEADER

    print {$fh} "PR_LIST_JSON=" . _shell_single_quote($json_for{PR_LIST}) . "\n";
    print {$fh} "PR_VIEW_JSON=" . _shell_single_quote($json_for{PR_VIEW}) . "\n";
    print {$fh} "GRAPHQL_JSON=" . _shell_single_quote($json_for{GRAPHQL}) . "\n";
    print {$fh} "ZENGINPL_CHECKRUNS_JSON=" . _shell_single_quote($json_for{ZENGINPL_CHECKRUNS}) . "\n";
    print {$fh} "API_CHECKRUNS_JSON=" . _shell_single_quote($json_for{API_CHECKRUNS}) . "\n";
    print {$fh} "MERGE_RESULT_JSON=" . _shell_single_quote($data{merge_result}) . "\n";
    print {$fh} "PR_DIFF_FILE=" . _shell_single_quote($pr_diff_file) . "\n";

    print {$fh} <<'MOCK_BODY';
for arg in "$@"; do
  if [[ "$arg" == repos/*/actions/* ]]; then
    if [[ "$arg" == *zengin-pl-api/* ]]; then
      fixture="$API_CHECKRUNS_JSON"; branch=chore/update-zengin-pl
    else
      fixture="$ZENGINPL_CHECKRUNS_JSON"; branch=master
    fi
    if [[ "$arg" == */workflows/* ]]; then
      sha="${arg#*head_sha=}"; sha="${sha%%&*}"
      jq -n --arg sha "$sha" --arg branch "$branch" '[{workflow_runs:[{id:123,run_attempt:1,head_sha:$sha,head_branch:$branch,event:"workflow_dispatch",status:"completed",conclusion:"success"}]}]'
    else
      jq '[{jobs:.check_runs}]' <<<"$fixture"
    fi
    exit 0
  fi
done
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  json="$PR_VIEW_JSON"
elif [[ "$1" == "pr" && "$2" == "diff" ]]; then
  cat "$PR_DIFF_FILE"; exit 0
elif [[ "$1" == "pr" && "$2" == "list" ]]; then
  json="$PR_LIST_JSON"
elif [[ "$1" == "api" && "$2" == "graphql" ]]; then
  json="$GRAPHQL_JSON"
elif [[ "$1" == "api" && "$2" == *"zengin-pl/commits/"*"/check-runs" ]]; then
  json="$ZENGINPL_CHECKRUNS_JSON"
elif [[ "$1" == "api" && "$2" == *"zengin-pl-api/commits/"*"/check-runs" ]]; then
  json="$API_CHECKRUNS_JSON"
elif [[ "$1" == "api" && "$2" == "--method" ]]; then
  echo "MERGE_CALLED $*" >> "$GH_CALL_LOG"
  printf '%s\n' "$MERGE_RESULT_JSON"
  exit 0
else
  echo "unhandled mock gh call: $*" >&2
  exit 1
fi

if [[ -n "$filter" ]]; then
  jq -r "$filter" <<<"$json"
else
  printf '%s\n' "$json"
fi
MOCK_BODY
    close $fh;
    chmod 0755, $gh;

    return $dir;
}

sub _shell_single_quote {
    my ($str) = @_;
    $str = q{} unless defined $str;
    $str =~ s/'/'\\''/g;
    return "'" . $str . "'";
}

