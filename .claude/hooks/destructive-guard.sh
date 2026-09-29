#!/usr/bin/env bash
# PreToolUse:Bash guard — blocks irreversible operations: git (staging, history,
# push/reset/clean), filesystem (recursive forced rm — only via .claude/bin/guarded-rm),
# prod DB (psql DROP/TRUNCATE/DELETE without WHERE), GitHub repo deletion. Exit 2 = block.
set -euo pipefail

block() {
  echo "BLOCKED: $1" >&2
  exit 2
}

# Исходы хука: 0 — разрешено, 2 — запрещено или ошибка проверки. Claude Code считает
# блокировкой только код 2, поэтому сбой зависимости (jq, perl, grep, sed) и любой
# неожиданный выход под set -e — тоже блокировка, а не пропуск (WP-023).
fail_check() {
  block "ошибка проверки destructive-guard ($1) — команда не пропущена. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
}
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    fail_check "неожиданный выход, код $rc"
  fi
}
trap on_exit EXIT

# Bypass: только из реального шелла пилота (тот же контракт, что secret-leak-block.sh —
# хук читает свой процессный env, не текст команды, агент не может выставить это сам себе).
# Строгое сравнение с "1" (не -n) — та же несогласованность в secret-leak-block.sh
# (там -n) допустима для существующего кода, но не стоит копировать её в новый
# (пир-ревью Codex, WP-544 Ф1, 20.08): -n пропустил бы CC_ALLOW_DESTRUCTIVE_INPUT=0 как bypass.
[ "${CC_ALLOW_DESTRUCTIVE_INPUT:-}" = "1" ] && exit 0

INPUT=$(cat) || fail_check "не прочитан вход"
CMD=$(jq -r '.tool_input.command // empty' <<< "$INPUT") || fail_check "jq не разобрал вход"
[ -z "$CMD" ] && exit 0
# cwd намеренно пуст — как и до WP-023, когда второй jq читал уже прочитанный stdin: правило путей
# от корня IWE ниже не срабатывает (включить его — отдельное решение владельца).
CWD=""
case "${BASH_SOURCE[0]}" in
  */*) HOOK_SRC=${BASH_SOURCE[0]%/*} ;;
  *) HOOK_SRC=. ;;
esac
HOOK_DIR="$(cd "$HOOK_SRC" && pwd -P)" || fail_check "каталог хука"
WORKSPACE_ROOT="$(cd "$HOOK_DIR/../.." && pwd -P)"
GUARDED_RM="$WORKSPACE_ROOT/.claude/bin/guarded-rm"

# grep по тексту без канала с ранним выходом (-c дочитывает ввод, SIGPIPE не бывает):
# 0 — есть совпадение, 1 — нет, код 2 и выше — ошибка проверки, а не «нет совпадения».
matches() {
  local text=$1 feed=0 found=0
  shift
  # Коды обеих частей конвейера — по отдельности: сбой printf при пустом вводе grep дал бы 1,
  # неотличимое от «нет совпадения» (подтверждение Codex, WP-023).
  { printf '%s\n' "$text" | grep -c "$@" >/dev/null; feed=${PIPESTATUS[0]} found=${PIPESTATUS[1]}; } || true
  [ "$feed" -eq 0 ] || fail_check "printf, код $feed"
  case "$found" in
    0|1) return "$found" ;;
    *) fail_check "grep, код $found" ;;
  esac
}

# #362: a top-level `cd` persists between Bash calls in Claude Code. Strip
# quoted spans before detecting command segments; `(cd ... && ...)` remains
# allowed because the opening parenthesis is not a top-level separator.
CD_RC=0
CMD_SCAN="$CMD" perl -e '
  my $s=$ENV{"CMD_SCAN"};
  $s =~ s/'"'"'[^'"'"']*'"'"'/ Q /g;
  $s =~ s/"(?:\\.|[^"\\])*"/ Q /g;
  exit($s =~ /(?:^|[;&|]\s*)cd\s+/ ? 0 : 1);
' || CD_RC=$?
case "$CD_RC" in
  0) block "верхнеуровневый cd запрещён: используй git -C <path>, абсолютный путь или (cd <path> && ...)." ;;
  1) ;;
  *) fail_check "perl, проверка cd, код $CD_RC" ;;
esac

if [ -n "$CWD" ]; then
  CWD_PHYSICAL=$(cd "$CWD" 2>/dev/null && pwd -P || printf '%s' "$CWD")
  if [ "$CWD_PHYSICAL" != "$WORKSPACE_ROOT" ] && \
     matches "$CMD" -E "(^|[[:space:]\"'])(\\.claude/|scripts/|memory/)"; then
    block "root-relative path вызван из cwd=$CWD_PHYSICAL; используй абсолютный путь от $WORKSPACE_ROOT."
  fi
fi

git_segment() {
  # Return a normalised shell segment only when `git <global-opts> <subcmd>`
  # is the command being executed. A regex over the raw command saw `git reset`
  # inside a quoted argument of another program as an actual Git command.
  local subcmd="$1"
  SUBCMD="$subcmd" CMD_SCAN="$CMD" perl -e '
    sub words {
      my ($text) = @_;
      my (@out, $word, $quote) = ();
      for (my $i = 0; $i < length($text); $i++) {
        my $char = substr($text, $i, 1);
        if (defined $quote) {
          if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
            $word .= substr($text, ++$i, 1);
          } elsif ($char eq $quote) {
            undef $quote;
          } else {
            $word .= $char;
          }
        } elsif ($char eq q{"} || $char eq chr(39)) {
          $quote = $char;
        } elsif ($char eq "\\" && $i + 1 < length($text)) {
          $word .= substr($text, ++$i, 1);
        } elsif ($char =~ /\s/) {
          push @out, $word if length $word;
          $word = q{};
        } else {
          $word .= $char;
        }
      }
      push @out, $word if length $word;
      return @out;
    }

    sub inspect_segment {
      my ($segment) = @_;
      my @tokens = words($segment);
      return unless @tokens;
      # A git token is an invocation at the command position (after assignments, shell keywords
      # and redirections) or as the command run by a wrapper at that position. Wrapper options are
      # skipped without an arity table; when the first non-option word after a wrapper is neither
      # git, another wrapper nor a data command, it may be an option argument, so the rest of the
      # segment is searched for git: a parse mistake errs toward a block (WP-023, Codex reviews 2-3).
      my %keyword = map { $_ => 1 } qw(! then do else elif if while until {);
      my %wrapper = map { $_ => 1 } qw(command time exec nohup env sudo doas xargs timeout nice ionice stdbuf watch chroot parallel);
      my %data = map { $_ => 1 } qw(echo printf : true false test [ which type man help grep egrep fgrep rg cat ls head tail wc sort uniq cut);
      my ($i, $in_wrapper) = (0, q{});
      while ($i < @tokens) {
        my $token = $tokens[$i];
        if (!$in_wrapper && ($token =~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $keyword{$token})) {
          $i++;
          next;
        }
        if ($token =~ /^(?:\d*|&)(?:>>?|<<?|>&|<&|>\|)$/) {
          $i += 2;
          next;
        }
        if ($token =~ /^(?:\d*|&)(?:>>?|<<?|>&|<&|>\|)./) {
          $i++;
          next;
        }
        if ($in_wrapper && ($token =~ /^-/ || $token =~ /^[A-Za-z_][A-Za-z0-9_]*=/)) {
          return if $in_wrapper eq "command" && $token =~ /^(?:-[pvV]*[vV]|--help)/;
          $i++;
          next;
        }
        my ($base) = $token =~ m{([^/\x5c]+)$};
        $base = q{} unless defined $base;
        $base =~ s/\.exe$//i;
        if ($base eq "git") {
          inspect_git(\@tokens, $i);
          return;
        }
        if ($wrapper{$base}) {
          $in_wrapper = $base;
          $i++;
          next;
        }
        # Only a command known not to run its arguments, at the command position itself, ends the
        # search. After any other command (strace, ssh, docker exec ...) and anywhere inside a
        # wrapper (the word may be an option argument: env -u cat git ...) every later git token
        # is checked (Codex review 4).
        return if $data{$base} && !$in_wrapper;
        for (my $j = $i + 1; $j < @tokens; $j++) {
          my ($later) = $tokens[$j] =~ m{([^/\x5c]+)$};
          inspect_git(\@tokens, $j) if defined $later && $later =~ /^git(?:\.exe)?$/i;
        }
        return;
      }
    }

    sub inspect_git {
      my ($tokens, $start) = @_;
      # Redirections inside the call are not arguments: drop them (an operator alone takes the next
      # word with it) and cut a flag glued to one (-A>/dev/null -> -A) (Codex review 4).
      my @call = ($tokens->[$start]);
      for (my $k = $start + 1; $k < @$tokens; $k++) {
        my $token = $tokens->[$k];
        if ($token =~ /^(?:\d*|&)(?:>>?|<<?|>&|<&|>\|)$/) {
          $k++;
          next;
        }
        next if $token =~ /^(?:\d*|&)(?:>>?|<<?|>&|<&|>\|)./;
        $token =~ s/\d*[<>].*$// if $token =~ /^-/;
        push @call, $token;
      }
      # A quoted argument looks like a redirection once quotes are stripped (git clean ">" -f):
      # check both the raw word list and the cleaned one, so neither view can hide a call.
      my %with_arg = map { $_ => 1 } qw(-C -c --git-dir --work-tree --namespace --super-prefix --config-env);
      for my $list ([@$tokens[$start .. $#$tokens]], \@call) {
        my $i = 1;
        while ($i < @$list && $list->[$i] =~ /^-/) {
          $i += $with_arg{$list->[$i]} ? 2 : 1;
        }
        next unless $i < @$list && $list->[$i] eq $ENV{"SUBCMD"};
        # Every invocation, one per line (WP-023: only the first one was checked before).
        (my $found = join(" ", @$list)) =~ s/[\r\n]+/ /g;
        print $found, "\n";
      }
    }

    # Split on unquoted ; & | ( ) ` and newlines. Backslash escapes and comments are honoured;
    # the & and | of 2>&1, &>, >| stay inside the command. After a here-document operator every
    # remaining line is scanned on its own with a fresh quote state, so a quote in the body cannot
    # hide a command after the delimiter (Codex review 3).
    sub scan {
      my ($text, $allow_heredoc) = @_;
      my ($segment, $quote, $heredoc, $escaped_at) = (q{}, undef, 0, -1);
      my $n = length $text;
      for (my $i = 0; $i < $n; $i++) {
        my $char = substr($text, $i, 1);
        my $next = $i + 1 < $n ? substr($text, $i + 1, 1) : q{};
        if (defined $quote) {
          $segment .= $char;
          if ($char eq "\\" && ($quote eq q{"} || $quote eq "ansi") && $i + 1 < $n) {
            $segment .= substr($text, ++$i, 1);
          } elsif ($char eq ($quote eq "ansi" ? chr(39) : $quote)) {
            undef $quote;
          }
        } elsif ($char eq "\$" && $next eq chr(39)) {
          $quote = "ansi";
          $segment .= $char . $next;
          $i++;
        } elsif ($char eq "\\" && $i + 1 < $n) {
          # An escaped character is literal: an escaped quote does not open a quote. (An escaped
          # separator is split by the v8 parser, whose calls are checked as well.)
          $segment .= $char . $next;
          $escaped_at = length $segment;
          $i++;
        } elsif ($char eq q{"} || $char eq chr(39)) {
          $quote = $char;
          $segment .= $char;
        } elsif ($char eq "#" && $escaped_at != length $segment && ($segment eq q{} || $segment =~ /[ \t]$/)) {
          my $end = index($text, "\n", $i);
          $i = ($end < 0 ? $n : $end) - 1;
        } elsif ($allow_heredoc && $char eq "<" && $next eq "<" && substr($text, $i + 2, 1) ne "<") {
          $heredoc = 1;
          $segment .= "<<";
          $i++;
        } elsif (($char eq "&" && ($segment =~ /[<>]$/ || $next eq ">")) || ($char eq "|" && $segment =~ />$/)) {
          $segment .= $char;
        } elsif ($char eq "\n" && $heredoc) {
          inspect_segment($segment);
          (my $rest = substr($text, $i + 1)) =~ s/\\\n//g;
          scan($_, 0) for split /\n/, $rest;
          return;
        } elsif ($char =~ /[;&|()\n]/ || $char eq q{`}) {
          inspect_segment($segment);
          $segment = q{};
        } else {
          $segment .= $char;
        }
      }
      inspect_segment($segment);
    }

    my $text = $ENV{"CMD_SCAN"};
    $text =~ s/\r\n/\n/g;
    scan($text, 1);
  '
}

git_segment_v8() {
  # Разбор git из v8 без изменений (WP-023): только первое вхождение, v8-разбивка.
  # Return a normalised shell segment only when `git <global-opts> <subcmd>`
  # is the command being executed. A regex over the raw command saw `git reset`
  # inside a quoted argument of another program as an actual Git command.
  local subcmd="$1"
  SUBCMD="$subcmd" CMD_SCAN="$CMD" perl -e '
    sub words {
      my ($text) = @_;
      my (@out, $word, $quote) = ();
      for (my $i = 0; $i < length($text); $i++) {
        my $char = substr($text, $i, 1);
        if (defined $quote) {
          if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
            $word .= substr($text, ++$i, 1);
          } elsif ($char eq $quote) {
            undef $quote;
          } else {
            $word .= $char;
          }
        } elsif ($char eq q{"} || $char eq chr(39)) {
          $quote = $char;
        } elsif ($char eq "\\" && $i + 1 < length($text)) {
          $word .= substr($text, ++$i, 1);
        } elsif ($char =~ /\s/) {
          push @out, $word if length $word;
          $word = q{};
        } else {
          $word .= $char;
        }
      }
      push @out, $word if length $word;
      return @out;
    }

    sub inspect_segment {
      my ($segment) = @_;
      my @tokens = words($segment);
      return unless @tokens;
      my $i = 0;
      while ($i < @tokens) {
        if ($tokens[$i] =~ /^[A-Za-z_][A-Za-z0-9_]*=/ ||
            $tokens[$i] =~ /^(?:command|env|nohup|time|sudo)$/) {
          $i++;
        } else {
          last;
        }
      }
      return unless $i < @tokens && $tokens[$i] eq "git";
      my $start = $i++;
      while ($i < @tokens) {
        if ($tokens[$i] =~ /^-C$/ || $tokens[$i] =~ /^--(?:git-dir|work-tree)$/ || $tokens[$i] =~ /^-c$/) {
          $i += 2;
        } elsif ($tokens[$i] =~ /^--(?:git-dir|work-tree)=/ || $tokens[$i] =~ /^-c/) {
          $i++;
        } else {
          last;
        }
      }
      return unless $i < @tokens && $tokens[$i] eq $ENV{"SUBCMD"};
      print join(" ", @tokens[$start .. $#tokens]), "\n";
      exit 0;
    }

    my $text = $ENV{"CMD_SCAN"};
    my ($segment, $quote) = (q{}, undef);
    for (my $i = 0; $i < length($text); $i++) {
      my $char = substr($text, $i, 1);
      if (defined $quote) {
        $segment .= $char;
        if ($char eq "\\" && $quote eq q{"} && $i + 1 < length($text)) {
          $segment .= substr($text, ++$i, 1);
        } elsif ($char eq $quote) {
          undef $quote;
        }
      } elsif ($char eq q{"} || $char eq chr(39)) {
        $quote = $char;
        $segment .= $char;
      } elsif ($char =~ /[;&|(){}]/ || $char eq q{`}) {
        inspect_segment($segment);
        $segment = q{};
      } else {
        $segment .= $char;
      }
    }
    inspect_segment($segment);
  '
}

is_git_subcmd() {
  [ -n "$(git_segment "$1")" ]
}

# Все вызовы `git <subcmd>` команды — в массив SEGMENTS: объединение нового разбора и разбора v8
# (git_segment_v8, дословно) — новый хук не может пропустить git-вызов, который видел v8. Сбой
# любого разбора — ошибка проверки. Строки делятся средствами оболочки, без отдельного процесса.
SEGMENTS=()
load_segments() {
  local text old rest line
  SEGMENTS=()
  text=$(git_segment "$1") || fail_check "perl, разбор git $1"
  old=$(git_segment_v8 "$1") || fail_check "perl, разбор git $1 (v8)"
  [ -n "$old" ] && SEGMENTS+=("$old")
  rest=$text
  while [ -n "$rest" ]; do
    line=${rest%%$'\n'*}
    [ -n "$line" ] && SEGMENTS+=("$line")
    [ "$line" = "$rest" ] && break
    rest=${rest#*$'\n'}
  done
  return 0
}

rm_violation() {
  # Exit 0 and print the reason when one command of $CMD on its own carries `rm`, a
  # recursive flag and a force flag (the same three whole-line tests as before), or when
  # the text has a construct the split does not handle; exit 1 when no command does.
  # The split may keep text of several Bash commands together, never cut one apart,
  # so it can only keep a block of the whole-line rule, never lose one (bug-2026-09-26).
  CMD_SCAN="$CMD" perl -e '
    use strict;
    use warnings;
    my $sq = chr(39);
    my $text = $ENV{"CMD_SCAN"};
    # jq on Windows prints embedded newlines as CRLF; a backslash before CR LF must stay a line continuation.
    $text =~ s/\r\n/\n/g;
    my $budget = 20 * length($text) + 100000;

    # Split one shell text into commands on unquoted ; & && | || |& and newlines of the
    # top level. Single, double and ANSI-C quotes, backslash escapes, $(...), ${...}, <(...),
    # >(...) and backticks stay inside the command that uses them; so do the & and | of the
    # >& <& &> >| redirections. Top-level comments are skipped; a word starts only after
    # the blanks of Bash (space, tab, newline) or an operator, not after other whitespace.
    # A top-level here-document
    # with a plain delimiter (WORD, quoted or escaped) is cut out and split separately (its
    # quotes cannot change the outer text) and checked as commands, as the whole-line rule
    # did. Anything else the split cannot follow for sure -- case, a here-document or a
    # comment inside a substitution, another delimiter form, an unterminated here-document,
    # nesting or volume beyond the limits -- is returned as a reason to keep the block.
    sub split_commands {
      my ($text, $depth, $commands, $bodies) = @_;
      return "case" if $text =~ /(?:^|[\s;&|(`])case\s/;
      return "вложенность here-document" if $depth > 3;
      $budget -= length $text;
      return "объём разбора" if $budget < 0;
      my (@stack, @pending);
      my $current = q{};
      my $escaped_at = -1;
      my $n = length $text;
      for (my $i = 0; $i < $n; $i++) {
        my $c = substr($text, $i, 1);
        my $next = $i + 1 < $n ? substr($text, $i + 1, 1) : q{};
        my $top = @stack ? $stack[-1] : q{};
        if ($top eq $sq) {
          $current .= $c;
          pop @stack if $c eq $sq;
          next;
        }
        if ($top eq "\$$sq") {
          $current .= $c;
          if ($c eq "\\" && $i + 1 < $n) {
            $current .= $next;
            $i++;
          } elsif ($c eq $sq) {
            pop @stack;
          }
          next;
        }
        if ($c eq "\\" && $i + 1 < $n) {
          $current .= $c . $next;
          $i++;
          $escaped_at = length $current;
          next;
        }
        if ($top eq q{"}) {
          $current .= $c;
          if ($c eq q{"}) {
            pop @stack;
          } elsif ($c eq "`") {
            push @stack, "`";
          } elsif ($c eq "\$" && ($next eq "(" || $next eq "{")) {
            $current .= $next;
            $i++;
            push @stack, $next;
          }
          next;
        }
        # Code: the top level or inside $(...), ${...}, <(...), >(...), backticks.
        my $last = length $current ? substr($current, -1) : q{};
        if ($c eq "#" && $top ne "{" && $escaped_at != length $current
            && ($last eq q{} || $last =~ /[ \t\n;&|()<>]/)) {
          return "комментарий внутри подстановки" if @stack;
          my $end = index($text, "\n", $i);
          $i = ($end < 0 ? $n : $end) - 1;
          next;
        }
        if ($c eq "<" && substr($text, $i, 3) eq "<<<") {
          $current .= "<<<";
          $i += 2;
          next;
        }
        if ($c eq "<" && $next eq "<") {
          return "here-document внутри подстановки" if @stack;
          pos($text) = $i + 2;
          return "ограничитель here-document"
            unless $text =~ /\G(-?)[ \t]*(?:([A-Za-z_][A-Za-z0-9_]*)|$sq([A-Za-z_][A-Za-z0-9_]*)$sq|"([A-Za-z_][A-Za-z0-9_]*)"|\x5c([A-Za-z_][A-Za-z0-9_]*))(?=[ \t\n;&|<>()]|$)/gc;
          my ($strip, $delimiter) = ($1, (grep { defined } $2, $3, $4, $5)[0]);
          my $end = pos($text);
          push @pending, [$delimiter, $strip eq "-"];
          $current .= substr($text, $i, $end - $i);
          $i = $end - 1;
          next;
        }
        if ($c eq "\n" && @pending) {
          return "here-document с незакрытой подстановкой" if @stack;
          my $p = $i + 1;
          for my $heredoc (@pending) {
            my ($delimiter, $strip) = @$heredoc;
            my ($body, $closed) = (q{}, 0);
            while ($p < $n) {
              my $end = index($text, "\n", $p);
              $end = $n if $end < 0;
              my $line = substr($text, $p, $end - $p);
              $p = $end + 1;
              my $bare = $line;
              $bare =~ s/^\t+// if $strip;
              if ($bare eq $delimiter) {
                $closed = 1;
                last;
              }
              $body .= "$line\n";
            }
            return "незавершённый here-document" unless $closed;
            push @$bodies, $body;
          }
          @pending = ();
          push @$commands, $current;
          $current = q{};
          $escaped_at = -1;
          $i = $p - 1;
          next;
        }
        if ($c eq $sq || $c eq q{"}) {
          push @stack, $c;
          $current .= $c;
          next;
        }
        if ($c eq "\$" && $next eq $sq) {
          push @stack, "\$$sq";
          $current .= $c . $next;
          $i++;
          next;
        }
        if ($c eq "`") {
          if ($top eq "`") {
            pop @stack;
          } else {
            push @stack, "`";
          }
          $current .= $c;
          next;
        }
        if (($c eq "\$" && ($next eq "(" || $next eq "{")) || ($c =~ /[<>]/ && $next eq "(")) {
          push @stack, $next;
          $current .= $c . $next;
          $i++;
          next;
        }
        if ($top eq "(" || $top eq "{") {
          $current .= $c;
          push @stack, $c if $c eq $top;
          pop @stack if $c eq ($top eq "(" ? ")" : "}");
          next;
        }
        if ($top eq "`") {
          $current .= $c;
          next;
        }
        if (($c eq "&" && ($last =~ /[<>]/ || $next eq ">")) || ($c eq "|" && $last eq ">")) {
          $current .= $c;
          next;
        }
        if ($c =~ /[;&|\n]/) {
          push @$commands, $current;
          $current = q{};
          $escaped_at = -1;
          $i++ if ($c eq "&" && $next eq "&") || ($c eq "|" && ($next eq "|" || $next eq "&"));
          next;
        }
        $current .= $c;
      }
      return "незавершённый here-document" if @pending;
      push @$commands, $current;
      return q{};
    }

    my @commands;
    my @texts = ([$text, 0]);
    while (@texts) {
      my ($part, $depth) = @{ shift @texts };
      my @bodies;
      my $construct = split_commands($part, $depth, \@commands, \@bodies);
      if ($construct) {
        print "разбор не поддерживает: $construct";
        exit 0;
      }
      push @texts, map { [$_, $depth + 1] } @bodies;
    }
    for my $command (@commands) {
      next unless $command =~ m{(?:^|\s|/|\x5c)rm(?:\s|$)}m
        && $command =~ /(?:^|\s)(?:-\S*[rR]\S*|--recursive)(?:\s|$)/m
        && $command =~ /(?:^|\s)(?:-\S*f\S*|--force)(?:\s|$)/m;
      (my $shown = $command) =~ s/\s+/ /g;
      $shown =~ s/^ //;
      # Show at most 200 characters, not bytes: the command arrives as UTF-8.
      if (utf8::decode($shown)) {
        $shown = substr($shown, 0, 200) . "\x{2026}" if length $shown > 200;
        utf8::encode($shown);
      } else {
        $shown = substr($shown, 0, 200) . "..." if length $shown > 200;
      }
      print "команда: $shown";
      exit 0;
    }
    exit 1;
  '
}

# git push --force / -f (allow the safe --force-with-lease)
load_segments push
for PUSH_SEGMENT in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
  PUSH_FORCE_SCAN=$(printf '%s\n' "$PUSH_SEGMENT" | sed -E 's/--force-with-lease(=[^[:space:]]*)?//g') || fail_check "sed"
  if matches "$PUSH_FORCE_SCAN" -E -- '(^|[[:space:]])(--force([[:space:]]|=|$)|-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$))'; then
    block "git push --force запрещён. Используй --force-with-lease или согласуй с владельцем (CLAUDE.md §2)."
  fi
done

# A hard reset is safe only when it cannot discard tracked work or local history:
# the tree must be clean and the target must contain the current HEAD. This still
# blocks resets that rewind a branch or erase uncommitted changes, while allowing
# a no-loss fast-forward reset used to repair a stale mirror.
reset_is_non_destructive() {
  local segment="$1" repo="${CWD:-$PWD}" target="" hard=false
  set -- $segment
  [ "${1:-}" = "git" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="${2:-}"; shift 2 ;;
      --git-dir|--work-tree|-c) shift 2 ;;
      --git-dir=*|--work-tree=*|-c*) shift ;;
      *) break ;;
    esac
  done
  [ "${1:-}" = "reset" ] || return 1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --hard) hard=true ;;
      --) shift; [ $# -eq 1 ] || return 1; target="$1"; break ;;
      -*) ;;
      *) [ -z "$target" ] || return 1; target="$1" ;;
    esac
    shift
  done
  [ "$hard" = true ] && [ -n "$target" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$repo" diff --quiet || return 1
  git -C "$repo" diff --cached --quiet || return 1
  git -C "$repo" merge-base --is-ancestor HEAD "$target" 2>/dev/null
}

# git reset --hard
# Исключение безвредного reset не действует, если в команде есть cd: проверялся бы не тот каталог.
load_segments reset
for RESET_SEGMENT in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
  if matches "$RESET_SEGMENT" -E -- '(^|[[:space:]])--hard([[:space:]]|$)' \
    && { matches "$CMD" -E '(^|[;&|(][[:space:]]*)cd[[:space:]]' || ! reset_is_non_destructive "$RESET_SEGMENT"; }; then
    block "git reset --hard запрещён (теряет незакоммиченное). Используй git stash."
  fi
done

# git clean with delete flags (-f/-d/-x)
load_segments clean
for CLEAN_SEGMENT in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
  if matches "$CLEAN_SEGMENT" -E -- '(^|[[:space:]])-[a-zA-Z]*[dfx]'; then
    block "git clean -fdx запрещён (удаляет неотслеживаемые файлы). Согласуй с владельцем."
  fi
done

# git add -A/--all/-u/--update/bare-dot (I7, WP-458: AR.216 жил только в rule-engine.sh
# check_git_staged_only(), которая никогда не диспатчилась ни на одно живое событие —
# реальная защита срабатывала только на commit (install-hooks.sh Check 8), уже после
# стейджа. Здесь — фактический PreToolUse барьер, до того как чужие файлы попадут в индекс.
# WP-544 Ф1 Д5, 21.08: перенесено из личной установки, где было с 17.07 — устраняет
# расхождение версий хука между личной установкой и этим шаблоном.)
load_segments add
for ADD_SEGMENT in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
  if matches "$ADD_SEGMENT" -E -- '(^|[[:space:]])(-A|--all|-u|--update)([[:space:]]|$)'; then
    block "git add -A/--all/-u/--update запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
  if matches "$ADD_SEGMENT" -E -- '(^|[[:space:]])\.([[:space:]]|$)'; then
    block "git add . запрещён — подхватывает файлы других агентов (CLAUDE.md §Git Staging). Стейдж конкретные пути: git add <path>."
  fi
done

# rm с одновременным recursive (-r/-R/--recursive) и force (-f/--force), в любом
# сочетании флагов (слитных или раздельных), включая /bin/rm, /usr/bin/rm и \rm, запрещён
# без исключений: удалять — через .claude/bin/guarded-rm, который при выполнении сверяет
# настоящие пути целей с реестром корней (.claude/config/guarded-rm-roots.txt). Прежнее
# исключение «временный путь где-то в строке» освобождало и удаление вне временных
# каталогов (WP-023, вариант Г). Признаки по всей строке — кандидат; блокируем, если все
# три несёт одна команда (bug-2026-09-26) или если разбор не справился.
if matches "$CMD" -E '(^|[[:space:]]|/|\\)rm([[:space:]]|$)' \
  && matches "$CMD" -E -- '(^|[[:space:]])(-[^[:space:]]*[rR][^[:space:]]*|--recursive)([[:space:]]|$)' \
  && matches "$CMD" -E -- '(^|[[:space:]])(-[^[:space:]]*f[^[:space:]]*|--force)([[:space:]]|$)'; then
  RM_RC=0
  RM_REASON=$(rm_violation) || RM_RC=$?
  if [ "$RM_RC" -ne 1 ]; then
    if [ "$RM_RC" -eq 0 ] && matches "$RM_REASON" -E '(^|[[:space:]])git([[:space:]]|$)'; then
      block "git rm с -r и -f запрещён — -f теряет незакоммиченные правки${RM_REASON:+ ($RM_REASON)}. Убери -f или согласуй с владельцем."
    fi
    block "rm с -r и -f запрещён — удаление необратимо${RM_REASON:+ ($RM_REASON)}. Удаляй той же командой через $GUARDED_RM (те же ключи и цели): он при выполнении проверит настоящие пути и удалит только внутри временных каталогов из реестра $WORKSPACE_ROOT/.claude/config/guarded-rm-roots.txt. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
  fi
fi

# psql: DROP/TRUNCATE — необратимая потеря структуры/данных.
if matches "$CMD" -iE '\bpsql\b' && matches "$CMD" -iE '\b(DROP[[:space:]]+(TABLE|SCHEMA|DATABASE)|TRUNCATE)\b'; then
  block "DROP/TRUNCATE через psql запрещён — необратимая потеря данных. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# psql: DELETE FROM без WHERE в том же операторе (эвристика: сегмент до ближайшего
# ';' или конца строки — не защищает от WHERE в другом statement той же команды).
if matches "$CMD" -iE '\bpsql\b' \
  && matches "$CMD" -iE 'DELETE[[:space:]]+FROM' \
  && ! matches "$CMD" -iE 'DELETE[[:space:]]+FROM[^;]*[[:space:]]WHERE([[:space:]]|$)'; then
  block "DELETE FROM без WHERE через psql запрещён — удалит всю таблицу. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

# удаление репозитория на GitHub — необратимо.
if matches "$CMD" -E '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
  block "gh repo delete запрещён — необратимо. Разовая необходимость: CC_ALLOW_DESTRUCTIVE_INPUT=1 из реального шелла пилота."
fi

exit 0
