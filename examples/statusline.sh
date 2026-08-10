#!/bin/bash
input=$(cat)

# --- Extract values from JSON ---
cwd=$(echo "$input" | jq -r '.cwd')
model=$(echo "$input" | jq -r '.model.display_name // .model.id // empty')
ctx_used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
# rate_limits only exists for subscription (Pro/Max) accounts
is_subscription=$(echo "$input" | jq -r 'has("rate_limits")')
fast_mode=$(echo "$input" | jq -r '.fast_mode // empty')
effort_level=$(echo "$input" | jq -r '.effort.level // empty')
thinking_enabled=$(echo "$input" | jq -r '.thinking.enabled // empty')

# --- Colors ---
RESET='\033[00m'
BOLD='\033[01m'
GREEN='\033[01;32m'
YELLOW='\033[00;33m'
CYAN='\033[00;36m'
MAGENTA='\033[00;35m'
# default foreground instead of white, so labels adapt to light/dark themes
WHITE='\033[00;39m'
# fixed mid-gray (256-color) instead of dim white, so it stays readable on light backgrounds
GRAY='\033[38;5;245m'

# --- Helper: build a compact progress bar (8 chars wide) ---
make_bar() {
  local pct="$1"
  local width="${2:-8}"
  local fill="${3:-█}"
  local empty="${4:-░}"
  local filled
  filled=$(echo "$pct $width" | awk '{n=int($1/100*$2+0.5); if(n<0)n=0; if(n>$2)n=$2; print n}')
  local bar=""
  for i in $(seq 1 "$filled"); do bar="${bar}${fill}"; done
  local rem=$((width - filled))
  for i in $(seq 1 "$rem"); do bar="${bar}${empty}"; done
  printf '%s' "$bar"
}

# --- Helper: pick color based on percentage ---
bar_color() {
  local pct="$1"
  if echo "$pct" | awk '{exit !($1 >= 85)}'; then
    printf '\033[00;31m'
  elif echo "$pct" | awk '{exit !($1 >= 60)}'; then
    printf '\033[00;33m'
  else
    printf '\033[00;32m'
  fi
}

# --- Helper: format unix timestamp as HH:MM ---
format_time() {
  local ts="$1"
  if [ -n "$ts" ] && [ "$ts" != "null" ]; then
    date -r "$ts" '+%H:%M' 2>/dev/null || date -d "@$ts" '+%H:%M' 2>/dev/null
  fi
}

# Accumulate everything into a single line
line=""

# --- 1. Working directory ---
short_cwd="${cwd/#$HOME/~}"
line="${line}$(printf "${GREEN}%s${RESET}" "$short_cwd")"

# --- 2. Git branch and modified file count ---
git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$git_branch" ]; then
  modified_count=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | grep -c '^.\(M\|A\|D\|R\|C\|U\| M\| A\| D\)')
  line="${line}$(printf " ${GRAY}on${RESET} ${MAGENTA}${BOLD}%s${RESET}" "$git_branch")"
  if [ "$modified_count" -gt 0 ] 2>/dev/null; then
    line="${line}$(printf " ${YELLOW}~%d${RESET}" "$modified_count")"
  fi
fi

# --- 3. Model ---
if [ -n "$model" ]; then
  line="${line}$(printf " ${GRAY}|${RESET} ${CYAN}%s${RESET}" "$model")"
fi

# --- 4. Mode flags (fast mode, reasoning effort, thinking) ---
flags=""
[ "$fast_mode" = "true" ] && flags="⚡"
if [ -n "$effort_level" ]; then
  flags="${flags}${flags:+ }effort:${effort_level}"
fi
[ "$thinking_enabled" = "true" ] && flags="${flags}${flags:+ }think"
if [ -n "$flags" ]; then
  line="${line}$(printf " ${GRAY}|${RESET} ${GRAY}%s${RESET}" "$flags")"
fi

# --- 5. Context window bar ---
if [ -n "$ctx_used_pct" ] && [ -n "$ctx_total" ]; then
  ctx_total_k=$(echo "$ctx_total" | awk '{printf "%.0fk", $1/1000}')
  ctx_bar=$(make_bar "$ctx_used_pct" 8 "█" "░")
  ctx_color=$(bar_color "$ctx_used_pct")
  line="${line}$(printf " ${GRAY}|${RESET} ctx:${ctx_color}%s${RESET}${WHITE}%.0f%%%s${RESET}" \
    "$ctx_bar" "$ctx_used_pct" "/${ctx_total_k}")"
fi

# --- 6. Token usage bar ---
if [ -n "$total_input" ] && [ -n "$ctx_total" ] && [ "$ctx_total" -gt 0 ] 2>/dev/null; then
  tok_pct=$(echo "$total_input $ctx_total" | awk '{printf "%.1f", $1/$2*100}')
  tok_in_k=$(echo "$total_input" | awk '{printf "%.0fk", $1/1000}')
  tok_label="${tok_in_k}"
  if [ -n "$total_output" ]; then
    tok_out_k=$(echo "$total_output" | awk '{printf "+%.0fk", $1/1000}')
    tok_label="${tok_in_k}${tok_out_k}"
  fi
  tok_bar=$(make_bar "$tok_pct" 8 "█" "░")
  tok_color=$(bar_color "$tok_pct")
  line="${line}$(printf " ${GRAY}|${RESET} tok:${tok_color}%s${RESET}${WHITE}%s${RESET}" \
    "$tok_bar" "$tok_label")"
fi

# --- 7. Quota / rate limit info ---
if [ -n "$five_hour_pct" ]; then
  fh_bar=$(make_bar "$five_hour_pct" 8 "█" "░")
  fh_color=$(bar_color "$five_hour_pct")
  fh_reset=$(format_time "$five_hour_reset")
  fh_str="$(printf " ${GRAY}|${RESET} 5h:${fh_color}%s${RESET}${WHITE}%.0f%%%s${RESET}" \
    "$fh_bar" "$five_hour_pct" "${fh_reset:+@${fh_reset}}")"
  line="${line}${fh_str}"
fi

if [ -n "$seven_day_pct" ]; then
  sd_bar=$(make_bar "$seven_day_pct" 8 "█" "░")
  sd_color=$(bar_color "$seven_day_pct")
  sd_reset=$(format_time "$seven_day_reset")
  sd_str="$(printf " ${GRAY}|${RESET} 7d:${sd_color}%s${RESET}${WHITE}%.0f%%%s${RESET}" \
    "$sd_bar" "$seven_day_pct" "${sd_reset:+@${sd_reset}}")"
  line="${line}${sd_str}"
fi

# --- 8. Session cost (API-key accounts only; subscribers pay flat rate) ---
if [ "$is_subscription" != "true" ] && [ -n "$cost_usd" ]; then
  cost_str=$(echo "$cost_usd" | awk '{ if ($1 >= 1) printf "$%.2f", $1; else printf "$%.3f", $1 }')
  line="${line}$(printf " ${GRAY}|${RESET} ${YELLOW}%s${RESET}" "$cost_str")"
fi

printf '%b\n' "$line"
