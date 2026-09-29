#!/usr/bin/env bash
# Check a commit message against docs/commits.md — used by the commit-msg hook
# and by hand.
#
# Why this exists, and what it deliberately refuses to do:
#
#   * The 19 commits already in this repository are Chinese prose subjects with
#     no type prefix ("修 diff 确认页的布局崩坏"). Rewriting pushed history to
#     make them fit costs far more than tidy subjects are worth, so nothing here
#     is retroactive: this only ever sees a message as it is being written. Run
#     it over the old log and everything fails — that is the documented baseline
#     (docs/commits.md §一), not a regression.
#   * The type list and the scope list are read out of docs/commits.md at run
#     time, between the `<!-- check-commit: types -->` and
#     `<!-- check-commit: scopes -->` markers. A list copied into this file as
#     well would drift, and the copy that drifts is always the enforced one.
#   * Exit 1 and exit 2 are kept apart on purpose. 1 means "the message breaks
#     the spec"; 2 means "this checker could not do its job" (unreadable message
#     file, empty stdin, tables that no longer parse). Folding the second into
#     the first turns a broken checker into a commit that merely looks
#     non-compliant, and the usual answer to a checker that cries wolf is
#     `--no-verify` — which turns the hook off for real violations too.
#   * Nothing here judges what a machine cannot judge: whether the body explains
#     *why*, whether the stated root cause is the real one, whether the subject
#     is short enough. docs/commits.md §五 argues each of those at length. The
#     rules below are format only.
#   * So this script must never be the reason a correct commit is blocked. It
#     stays quiet where it cannot see (R6 with no readable index), it skips R4
#     with a warning when python3 is missing rather than failing the commit, and
#     it answers an empty message or binary junk with a rule violation, never
#     with a crash or a hang.
#
# Environment notes: macOS ships bash 3.2, so no `mapfile`/`readarray`, no
# `${var^^}`, no associative arrays, and BSD grep/sed (no `grep -P`). Purely
# structural matching is pinned to LC_ALL=C so it is byte-wise and cannot be
# changed by whatever locale a GUI git client hands the hook; the locale is
# instead forced to UTF-8 where character lengths matter (R3), because under
# LC_ALL=C a single 汉字 is three "characters" wide and `feat: 加` would look
# long enough.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$HERE/../docs/commits.md"

# The UTF-8 byte order mark, which git does not strip from a message file.
BOM="$(printf '\357\273\277')"

# Longest line this script looks at. See normalize_message: bash 3.2's pattern
# operations are quadratic on long strings, so a one-line 1 MB message used to
# freeze the commit-msg hook for about a minute. Truncating here cannot change
# any verdict — a type prefix is under 40 characters, and clip() truncates what
# gets displayed anyway.
MAX_LINE=8192

# R5: types that change behaviour, so the message must carry the reasoning.
# docs/commits.md §五 states this in prose; unlike the two lists it has no
# machine-readable table, so this is the one list that also lives here.
BODY_REQUIRED=" feat fix refactor perf "

# R4: Han detection. Python's `re` has no `\p{Han}`, so the ranges below are the
# equivalent, with `unicodedata` covering the compatibility ideographs.
HAN_PY='
import sys, unicodedata
data = sys.stdin.buffer.read().decode("utf-8", "ignore")
def han(ch):
    cp = ord(ch)
    if 0x3400 <= cp <= 0x4DBF or 0x4E00 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF:
        return True
    if 0x20000 <= cp <= 0x2FA1F:
        return True
    name = unicodedata.name(ch, "")
    return "CJK UNIFIED IDEOGRAPH" in name or "CJK COMPATIBILITY IDEOGRAPH" in name
# The verdict goes on stdout, not in the exit code: python exits 1 both for
# "no Han character" and for its own failures (stub interpreter, SyntaxError in
# this very snippet), and reading a failed run as "no Han" would block a
# perfectly good Chinese subject.
sys.stdout.write("han\n" if any(han(c) for c in data) else "none\n")
'

# ---------------------------------------------------------------------------
# Locale: only R3's character count depends on it.
# ---------------------------------------------------------------------------
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*UTF-8* | *utf8* | *UTF8*) ;;
	*) export LC_ALL="en_US.UTF-8" ;; # absent on this machine → bash silently falls back to C
esac

# ---------------------------------------------------------------------------
# Output. Violations go to stderr so they surface under `git commit`; the one
# success line goes to stdout.
# ---------------------------------------------------------------------------
VIOLATIONS=0

violation() { # $1 = rule id, $2 = what is wrong
	VIOLATIONS=$((VIOLATIONS + 1))
	printf '✗ %s %s\n' "$1" "$2" >&2
}

hint() { # a follow-up line belonging to the violation above it
	printf '    %s\n' "$1" >&2
}

note() { printf '!! %s\n' "$1" >&2; }

# Exit 2: the checker could not do its job. Kept visually distinct from a
# violation, and says so, so nobody reads it as "your message is bad".
unusable() { # $1 = headline, remaining args = detail lines
	printf '!! %s\n' "$1" >&2
	shift
	while [[ $# -gt 0 ]]; do
		printf '   %s\n' "$1" >&2
		shift
	done
	printf '   （退出码 2：脚本读不到自己的输入，和提交信息本身无关。）\n' >&2
	exit 2
}

# Wrap a word list in backticks for display: "feat fix" → "`feat` `fix`".
quote_list() {
	printf '%s' "$1" | LC_ALL=C sed -E 's/([^ ]+)/`\1`/g'
}

# Long subjects are truncated for display only. A 1 MB subject is a real case
# (generated messages), and dumping it whole into the terminal would bury every
# other violation.
clip() {
	local s="$1"
	if [[ ${#s} -gt 160 ]]; then
		s="${s:0:160}…"
	fi
	printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Help / usage
# ---------------------------------------------------------------------------
usage() {
	cat <<'EOF'
用法：check-commit.sh [选项] [消息文件]

  消息文件      提交信息所在的文件；省略或写 `-` 时从标准输入读。
                两者都没有、标准输入又是终端时直接报错退出（否则会挂在那里等人打字）。
  选项：
    -q, --quiet   不打印通过时的那一行（报错照常打印）
    --no-paths    跳过 R6（不读暂存区，因此也不检查 `docs` 类型动了哪些文件）
    -h, --help    显示这份帮助
  示例：
    Tools/check-commit.sh .git/COMMIT_EDITMSG
    echo 'feat(core): 加 TOML 表级修补' | Tools/check-commit.sh

规则（细则与两张清单见 docs/commits.md §六；类型表和范围表由本脚本每次运行时从
docs/commits.md 里读，不写死在脚本里）：
  R1  标题形如 `<类型>(<范围>): 内容`，类型必须在类型表里；`: ` 和 `：` 都认，大小写都认
  R2  写了范围就必须在范围表里；`feat(): …` 这种空范围不算写了范围，一样报错
  R3  分隔符后面要有实际内容 —— `feat:` 后面没话说不行
  R4  标题至少有一个汉字（需要 python3；没有 python3 时跳过并警告）
  R5  `feat` / `fix` / `refactor` / `perf` 必须有正文，正文至少一行
  R6  类型写 `docs` 时，暂存区里必须有 `docs/**` 或 `*.md`。
      只在能读到 git 暂存区、且确实有暂存改动时检查；不是 git 仓库或没暂存改动就跳过。
  R6 不想跑（例如正在改这个脚本自己）：加 --no-paths
  豁免：标题以 `Merge ` / `Revert "` / `fixup!` / `squash!` 开头 ——
        git 自己生成的消息，格式不归人管，直接通过。

退出码：
  0  合规（或命中豁免）
  1  消息不合规（R1–R6；一次列出全部问题，每行带规则号）
  2  脚本无法完成检查：消息文件读不到/是目录、标准输入是空的、
     docs/commits.md 里两段表格读不出来，或既没给文件标准输入又是终端

`git commit` 下绕过检查：git commit --no-verify（先确认不是消息写错了）
EOF
}

usage_short() {
	cat >&2 <<'EOF'
用法：check-commit.sh [选项] [消息文件]
  消息文件省略或写 `-` 时从标准输入读。选项见 check-commit.sh --help。
EOF
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
MSG_FILE=""
QUIET=0
NO_PATHS=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h | --help)
			usage
			exit 0
			;;
		-q | --quiet)
			QUIET=1
			shift
			;;
		--no-paths)
			NO_PATHS=1
			shift
			;;
		--)
			shift
			break
			;;
		-)
			[[ -z "$MSG_FILE" ]] || { printf '!! 消息文件给了不止一个：%s\n\n' "$MSG_FILE" >&2; usage_short; exit 2; }
			MSG_FILE="-"
			shift
			;;
		-*)
			printf '!! 不认识的选项：%s\n\n' "$1" >&2
			usage_short
			exit 2
			;;
		*)
			[[ -z "$MSG_FILE" ]] || { printf '!! 消息文件给了不止一个：%s\n\n' "$MSG_FILE" >&2; usage_short; exit 2; }
			MSG_FILE="$1"
			shift
			;;
	esac
done
[[ $# -eq 0 ]] || { printf '!! 多出来的参数：%s\n\n' "$*" >&2; usage_short; exit 2; }

if [[ -z "$MSG_FILE" ]] && [[ -t 0 ]]; then
	printf '!! 没有消息文件，标准输入又是终端。\n\n' >&2
	usage_short
	exit 2
fi

# ---------------------------------------------------------------------------
# docs/commits.md — the single source of truth for types and scopes
# ---------------------------------------------------------------------------
# The lines between the two markers of one table block; empty when the block or
# a marker is gone. The marker has to be a line of its own: docs/commits.md §intro
# *names* both markers inside a sentence, and a substring match would start the
# "types" block at that sentence and end up feeding prose into the type list.
doc_block() { # $1 = types | scopes
	# `close` and `open` are awk builtins — hence the names.
	LC_ALL=C awk -v start="<!-- check-commit: $1 -->" \
		-v stop="<!-- /check-commit: $1 -->" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/[ \t\r]+$/, "", line)
		}
		line == start { inside = 1; next }
		line == stop  { inside = 0; next }
		inside        { print }
	' "$DOC"
}

# The first column of a table row, when it is a bare word in backticks. The
# header row ("| 类型 | … |") and the `|---|` rule row carry no backticks, so
# they drop out here: the shape of the row, not its position, marks it as data.
# Extra columns and a different column order are therefore fine.
doc_list() {
	LC_ALL=C sed -nE 's/^[[:space:]]*\|[[:space:]]*`([A-Za-z][A-Za-z0-9+._-]*)`[[:space:]]*\|.*$/\1/p'
}

drop_dupes() {
	LC_ALL=C awk '!seen[$0]++'
}

DOC_TYPES=""
DOC_TYPES_LC=""
DOC_SCOPES=""
DOC_SCOPES_LC=""

load_doc() {
	if [[ ! -f "$DOC" || ! -r "$DOC" ]]; then
		unusable "读不到 ${DOC}。" \
			"类型表和范围表是这份脚本的输入：改表就是改规则，脚本不另外存一份清单。"
	fi

	local types scopes
	types="$(doc_block types | doc_list | drop_dupes | LC_ALL=C tr '\n' ' ')"
	types="${types% }"
	scopes="$(doc_block scopes | doc_list | drop_dupes | LC_ALL=C tr '\n' ' ')"
	scopes="${scopes% }"

	if [[ -z "$types" ]]; then
		unusable "docs/commits.md 里的类型表读不出任何一行。" \
			"期望 <!-- check-commit: types --> 与 <!-- /check-commit: types --> 之间，" \
			"每行形如：| \`feat\` | 什么时候用 | 例子 |（第一列必须是反引号包起来的裸词）。"
	fi
	if [[ -z "$scopes" ]]; then
		unusable "docs/commits.md 里的范围表读不出任何一行。" \
			"期望 <!-- check-commit: scopes --> 与 <!-- /check-commit: scopes --> 之间，" \
			"每行形如：| \`core\` | 覆盖什么 | 例子 |（第一列必须是反引号包起来的裸词）。"
	fi

	DOC_TYPES="$types"
	DOC_SCOPES="$scopes"
	DOC_TYPES_LC="$(printf '%s' "$types" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	DOC_SCOPES_LC="$(printf '%s' "$scopes" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
}

in_list() { # $1 = needle (lower case), $2 = space separated haystack (lower case)
	case " $2 " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# ---------------------------------------------------------------------------
# Read the message. A missing/unreadable file is exit 2; an *empty* file is not
# — it goes on to fail R1 like any other message without a type prefix.
# ---------------------------------------------------------------------------
RAW=""
read_message() {
	if [[ -n "$MSG_FILE" && "$MSG_FILE" != "-" ]]; then
		if [[ -d "$MSG_FILE" ]]; then
			unusable "消息文件是个目录：$MSG_FILE"
		fi
		if [[ ! -r "$MSG_FILE" ]]; then
			unusable "读不到消息文件：$MSG_FILE"
		fi
		# NUL bytes are dropped so bash never has to warn about them; a binary
		# message then simply fails R1 instead of crashing anything.
		RAW="$(LC_ALL=C tr -d '\000' <"$MSG_FILE")" || unusable "读消息文件失败：$MSG_FILE"
	else
		RAW="$(LC_ALL=C tr -d '\000')" || unusable "读标准输入失败。"
		if [[ -z "$RAW" ]]; then
			unusable "标准输入是空的，没有提交信息可查。" \
				"（文件是空的另有说法：按不合规处理、退出码 1；空的标准输入则算脚本没拿到输入。）"
		fi
	fi
}

# ---------------------------------------------------------------------------
# Normalise: drop CR, drop `#` comment lines and trailers, take the first
# remaining non-empty line as the subject, the rest as the body.
# ---------------------------------------------------------------------------
SUBJECT=""
SUBJECT_RAW="" # the subject line before the MAX_LINE cap; only R4 reads it
BODY_LINES=0

# Trailers git or reviewers append; they say nothing about the change itself and
# must not be mistaken for the body R5 asks for.
TRAILER_KEYS=" signed-off-by co-authored-by reviewed-by acked-by tested-by change-id "

is_trailer() { # $1 = one trimmed line
	local line="$1" key
	case "$line" in
		[A-Za-z-]*:*) ;;
		*) return 1 ;;
	esac
	key="${line%%:*}"
	case "$key" in
		'' | *[!A-Za-z-]*) return 1 ;;
	esac
	key="$(printf '%s' "$key" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	case "$TRAILER_KEYS" in
		*" $key "*) return 0 ;;
	esac
	return 1
}

normalize_message() {
	local line raw trimmed
	SUBJECT=""
	SUBJECT_RAW=""
	BODY_LINES=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Cap before the pattern operations below: `${s%$'\r'}` and `${s#"$BOM"}` are
		# quadratic in bash 3.2 — measured 26 s each on a 400k-character line, so a
		# single-line 1 MB message froze the hook for a minute. The cap cannot change
		# R1–R3, R5 or R6: a type prefix is under 40 characters. R4 is the exception —
		# it reads the uncapped line kept in SUBJECT_RAW, so a Han character sitting
		# past the cap is still found instead of being reported as "no Chinese in the
		# subject" and blocking a correct commit.
		raw="$line"
		if [[ ${#line} -gt $MAX_LINE ]]; then line="${line:0:$MAX_LINE}"; fi
		line="${line%$'\r'}"
		line="${line#"$BOM"}"
		trimmed="${line#"${line%%[![:space:]]*}"}"        # drop leading blanks
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"  # drop trailing blanks
		case "$trimmed" in
			'#'*) continue ;; # git's own comments
		esac
		if [[ -z "$SUBJECT" ]]; then
			[[ -n "$trimmed" ]] || continue
			SUBJECT="$trimmed"
			SUBJECT_RAW="$raw"
			continue
		fi
		[[ -n "$trimmed" ]] || continue
		if is_trailer "$trimmed"; then
			continue
		fi
		BODY_LINES=$((BODY_LINES + 1))
	done <<<"$RAW"
}

# ---------------------------------------------------------------------------
# Split the subject into type / scope / rest, using the shape from R1:
# <TYPE> [(<SCOPE>)] [!] :|： with optional blanks around each piece.
# ---------------------------------------------------------------------------
SUBJ_TYPE=""
SUBJ_SCOPE=""
SUBJ_HAS_SCOPE=0
SUBJ_REST=""

parse_subject() {
	SUBJ_TYPE="$(printf '%s\n' "$SUBJECT" | LC_ALL=C sed -nE \
		's/^[[:space:]]*([A-Za-z]+)[[:space:]]*(\([^()]*\))?[[:space:]]*!?[[:space:]]*[:：].*$/\1/p')"
	if printf '%s\n' "$SUBJECT" | LC_ALL=C grep -Eq \
		'^[[:space:]]*[A-Za-z]+[[:space:]]*\([^()]*\)[[:space:]]*!?[[:space:]]*[:：]'; then
		SUBJ_HAS_SCOPE=1
		SUBJ_SCOPE="$(printf '%s\n' "$SUBJECT" | LC_ALL=C sed -nE \
			's/^[[:space:]]*[A-Za-z]+[[:space:]]*\(([^()]*)\)[[:space:]]*!?[[:space:]]*[:：].*$/\1/p')"
	fi
	if [[ -n "$SUBJ_TYPE" ]]; then
		SUBJ_REST="$(printf '%s\n' "$SUBJECT" | LC_ALL=C sed -nE \
			's/^[[:space:]]*[A-Za-z]+[[:space:]]*(\([^()]*\))?[[:space:]]*!?[[:space:]]*[:：][[:space:]]*//p')"
		SUBJ_REST="${SUBJ_REST%"${SUBJ_REST##*[![:space:]]}"}"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
read_message
normalize_message

# Exemptions come before every rule, and before the doc is read: a merge or a
# fixup is git's message, not a human's, so a mangled type table is no reason to
# block it either.
if [[ -n "$SUBJECT" ]]; then
	EXEMPT=""
	case "$SUBJECT" in
		'Merge '*) EXEMPT="标题以 Merge 开头（git 的合并消息）" ;;
		'Revert "'*) EXEMPT="标题以 Revert \" 开头（git 的回滚消息）" ;;
		'fixup!'*) EXEMPT="标题以 fixup! 开头（git 的 fixup 提交）" ;;
		'squash!'*) EXEMPT="标题以 squash! 开头（git 的 squash 提交）" ;;
	esac
	if [[ -n "$EXEMPT" ]]; then
		[[ $QUIET -eq 1 ]] || printf '✓ 豁免：%s，格式不归人管。\n' "$EXEMPT"
		exit 0
	fi
fi

load_doc

parse_subject

TYPE_LC=""
TYPE_OK=0

# R1 — type prefix, and the type has to be in the doc's list.
if [[ -z "$SUBJ_TYPE" ]]; then
	if [[ -n "$SUBJECT" ]]; then
		violation R1 "标题没有类型前缀：$(clip "$SUBJECT")"
	else
		# An empty message and an all-comments one land here; saying "标题："
		# with nothing after it reads like the checker truncated something.
		violation R1 "标题是空的：消息里没有一行不是空行或注释"
	fi
	hint "写成 <类型>(<范围>): 为什么这么改 —— 例如 feat(core): 加 TOML 表级修补"
	hint "类型清单（docs/commits.md 类型表）：$(quote_list "$DOC_TYPES")"
else
	TYPE_LC="$(printf '%s' "$SUBJ_TYPE" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
	if in_list "$TYPE_LC" "$DOC_TYPES_LC"; then
		TYPE_OK=1
	else
		violation R1 "类型 \`$SUBJ_TYPE\` 不在类型表里：$(clip "$SUBJECT")"
		hint "类型清单（docs/commits.md 类型表）：$(quote_list "$DOC_TYPES")"
	fi
fi

# R2 — a written scope has to be in the doc's list. An empty `feat()` counts as
# written, so it is checked here rather than silently treated as absent.
if [[ -n "$SUBJ_TYPE" && $SUBJ_HAS_SCOPE -eq 1 ]]; then
	if [[ -z "$SUBJ_SCOPE" ]]; then
		violation R2 "范围是空的（写成了 \`()\`）：$(clip "$SUBJECT")"
		hint "写了括号就得填一个清单里的范围；不想要范围就把括号整个删掉"
		hint "范围清单（docs/commits.md 范围表）：$(quote_list "$DOC_SCOPES")"
	else
		SCOPE_LC="$(printf '%s' "$SUBJ_SCOPE" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
		if ! in_list "$SCOPE_LC" "$DOC_SCOPES_LC"; then
			violation R2 "范围 \`$SUBJ_SCOPE\` 不在范围表里：$(clip "$SUBJECT")"
			hint "范围清单（docs/commits.md 范围表）：$(quote_list "$DOC_SCOPES")"
			hint "范围不写也行；要加新范围，就往 docs/commits.md 的范围表里加一行"
			hint "（<!-- check-commit: scopes --> 与 <!-- /check-commit: scopes --> 之间）——"
			hint "这张表就是清单本身，脚本每次运行都重新读它，没有第二份写死的名单。"
		fi
	fi
fi

# R3 — a prefix with nothing after it is not a subject.
if [[ -n "$SUBJ_TYPE" && ${#SUBJ_REST} -lt 2 ]]; then
	violation R3 "分隔符后面没有实际内容：$(clip "$SUBJECT")"
	hint "标题不能只有前缀：说清为什么改，至少两个字（\`feat:\` 这种不算）"
fi

# R4 — the subject is Chinese. Skipped, with a warning, when the tooling for it
# is missing: a missing python3 must never block somebody's commit.
if [[ -n "$SUBJECT" ]]; then
	PY_BIN="$(command -v python3 2>/dev/null || true)"
	if [[ -z "$PY_BIN" ]]; then
		note "R4 跳过：找不到 python3，无法检查标题里有没有汉字。"
	else
		PY_OUT="$("$PY_BIN" -c "$HAN_PY" <<<"${SUBJECT_RAW:-$SUBJECT}" 2>/dev/null || true)"
		case "$PY_OUT" in
			han) ;;
			none)
				violation R4 "标题里没有汉字：$(clip "$SUBJECT")"
				hint "标题用中文说为什么改（正文里的英文报错、栈、命令不受影响）"
				;;
			*)
				note "R4 跳过：python3 没能给出判断（输出为空或异常），这一条不拦。"
				;;
		esac
	fi
fi

# R5 — behaviour-changing types need a body.
if [[ $TYPE_OK -eq 1 ]]; then
	case "$BODY_REQUIRED" in
		*" $TYPE_LC "*)
			if [[ $BODY_LINES -eq 0 ]]; then
				violation R5 "类型 \`$SUBJ_TYPE\` 必须有正文，现在只有标题一行"
				hint "正文写根因、证据（断言/截图/日志）、为什么不选另一条路 —— docs/commits.md §五"
			fi
			;;
	esac
fi

# R6 — `docs` has to actually touch documentation. Checked only when an index is
# readable and holds staged changes; otherwise this stays silent on purpose.
if [[ $TYPE_OK -eq 1 && "$TYPE_LC" == "docs" && $NO_PATHS -eq 0 ]]; then
	TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	if [[ -n "$TOPLEVEL" ]]; then
		# -C "$TOPLEVEL": run from a subdirectory, `git diff --cached` would only
		# list paths under it, and a docs/ change staged outside would be missed.
		STAGED="$(git -C "$TOPLEVEL" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)"
		if [[ -n "$STAGED" ]]; then
			if ! printf '%s\n' "$STAGED" | LC_ALL=C grep -Eq '^(docs/.*|.*\.md)$'; then
				STAGED_COUNT="$(printf '%s\n' "$STAGED" | LC_ALL=C wc -l | LC_ALL=C tr -d ' ')"
				STAGED_SHOWN="$(printf '%s\n' "$STAGED" | LC_ALL=C head -n 6 | LC_ALL=C tr '\n' ' ')"
				if [[ "$STAGED_COUNT" -gt 6 ]]; then
					STAGED_SHOWN="${STAGED_SHOWN}…"
				fi
				violation R6 "类型是 docs，但暂存区里没有 docs/ 下的文件，也没有 *.md"
				hint "暂存了 $STAGED_COUNT 个文件：$(clip "$STAGED_SHOWN")"
				hint "要么把文档改动一起暂存，要么换成真正的类型（改的是代码就不是 docs）"
				hint "确认不是这个问题（例如只想先提交文档脚本），加 --no-paths 跳过 R6"
			fi
		fi
	fi
fi

if [[ $VIOLATIONS -gt 0 ]]; then
	printf '\n共 %d 处不合规。规范、类型表、范围表都在 docs/commits.md。\n' "$VIOLATIONS" >&2
	exit 1
fi

if [[ $QUIET -eq 0 ]]; then
	if [[ -n "$SUBJ_SCOPE" ]]; then
		printf '✓ 提交信息合规：类型 %s、范围 %s、正文 %d 行（规范见 docs/commits.md）\n' \
			"$SUBJ_TYPE" "$SUBJ_SCOPE" "$BODY_LINES"
	else
		printf '✓ 提交信息合规：类型 %s、无范围、正文 %d 行（规范见 docs/commits.md）\n' \
			"$SUBJ_TYPE" "$BODY_LINES"
	fi
fi
exit 0
