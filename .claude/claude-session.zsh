# SPDX-License-Identifier: Apache-2.0

# claude-session.zsh — name and color each Claude Code session after its repository.
#
# Install as an oh-my-zsh custom file, which oh-my-zsh auto-sources from
# $ZSH_CUSTOM/*.zsh (see oh-my-zsh.sh, "for config_file"). No plugins=() entry
# is needed:
#
#   cp .claude/claude-session.zsh "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/claude-session.zsh"
#   exec zsh
#
# Without oh-my-zsh, source it from ~/.zshrc instead:
#
#   source /path/to/claude-session.zsh

# >>> claude session name = org/repo >>>
# Name each new Claude Code session after the git repository it starts in
# (org/repo from the origin remote, else the main checkout's directory, else
# the current directory) and give it a stable prompt-bar color hashed from that
# name. The color is applied by passing `/color <name>` as the initial prompt,
# so it is skipped when a prompt is supplied. Everything is skipped when a name
# is given, a session is resumed/continued, for print mode, help/version, and
# for subcommands.
_claude_repo_name() {
  local url common
  if url=$(git remote get-url origin 2>/dev/null) && [[ -n $url ]]; then
    url=${${url%.git}%/}
    url=${url//://}
    print -r -- ${url:h:t}/${url:t}
  elif common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    print -r -- ${common:h:t}
  else
    print -r -- ${PWD:t}
  fi
}

_claude_color_for() {
  local -a colors=(red blue green yellow purple orange pink cyan)
  local sum=${$(print -rn -- $1 | cksum)[1]}
  print -r -- ${colors[sum % ${#colors} + 1]}
}

claude() {
  local arg name expect_value=0 has_prompt=0
  case $1 in
    agents|attach|auth|auto-mode|doctor|gateway|import|install|kill|logs|mcp|plugin|plugins|project|respawn|rm|setup-token|stop|ultrareview|update|upgrade)
      command claude "$@"; return ;;
  esac
  for arg in "$@"; do
    if (( expect_value )); then expect_value=0; continue; fi
    case $arg in
      -n|--name|--name=*|-r|--resume|--resume=*|-c|--continue|--from-pr|--from-pr=*|--session-id|--session-id=*|-p|--print|-h|--help|-v|--version)
        command claude "$@"; return ;;
      --add-dir|--agent|--agents|--allowedTools|--allowed-tools|--append-system-prompt|--disallowedTools|--disallowed-tools|--effort|--environment|--fallback-model|--mcp-config|--model|--permission-mode|--plugin-dir|--plugin-url|--settings|--setting-sources|--system-prompt)
        expect_value=1 ;;
      --) has_prompt=1; break ;;
      -*) ;;
      *) has_prompt=1 ;;
    esac
  done
  name=$(_claude_repo_name)
  if (( has_prompt )); then
    command claude -n "$name" "$@"
  else
    command claude -n "$name" "/color $(_claude_color_for $name)" "$@"
  fi
}
# <<< claude session name = org/repo <<<
