#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

MAX_BLOCK_SIZE=$((4 * 1024 * 1024))
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/tmux/history"
CLIP_ROOT="${STATE_ROOT}/clipboard"
PANE_ROOT="${STATE_ROOT}/panes"

usage() {
  cat <<'EOF'
tmux-history.sh commands:
  store-clipboard [--source SRC] [--context CTX]    # read stdin, persist clipboard entry
  import-clipboard [--source SRC]                    # read system clipboard, persist it
  restore-clipboard <N|ID>                           # restore entry to tmux/system clipboard
  list-clipboard [LIMIT]                             # list clipboard history
  clear-clipboard                                    # clear persisted clipboard history

  save-panes [--source SRC]                          # persist all pane/PTY histories
  list-panes [LIMIT]                                 # list pane snapshots
  show-pane <N|ID>                                   # print pane snapshot to stdout
  clear-panes                                        # clear persisted pane history

  count <clipboard|panes>                            # print number of persisted entries
  menu                                               # interactive tmux history menu

  pane-daemon-start [INTERVAL_SECONDS]               # start periodic pane snapshot daemon
  pane-daemon-stop                                   # stop pane snapshot daemon
  pane-daemon-loop [INTERVAL_SECONDS]                # internal daemon loop
EOF
}

ensure_layout() {
  mkdir -p "${CLIP_ROOT}/entries" "${PANE_ROOT}/entries" "${PANE_ROOT}/last"
  [ -f "${CLIP_ROOT}/index.tsv" ] || : >"${CLIP_ROOT}/index.tsv"
  [ -f "${PANE_ROOT}/index.tsv" ] || : >"${PANE_ROOT}/index.tsv"
}

sanitize_meta_value() {
  printf '%s' "${1:-}" | tr '\t\r\n' ' '
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi
  shasum -a 256 "$file" | awk '{print $1}'
}

index_path() {
  case "$1" in
    clipboard) printf '%s\n' "${CLIP_ROOT}/index.tsv" ;;
    panes) printf '%s\n' "${PANE_ROOT}/index.tsv" ;;
    *)
      printf 'unknown history type: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

entries_root() {
  case "$1" in
    clipboard) printf '%s\n' "${CLIP_ROOT}" ;;
    panes) printf '%s\n' "${PANE_ROOT}" ;;
    *)
      printf 'unknown history type: %s\n' "$1" >&2
      exit 1
      ;;
  esac
}

append_index() {
  local index_file="$1"
  local line="$2"
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"${index_file}"
    flock -x 9
    printf '%s\n' "${line}" >&9
    flock -u 9
    exec 9>&-
    return
  fi
  printf '%s\n' "${line}" >>"${index_file}"
}

entry_dir() {
  local type="$1"
  local id="$2"
  printf '%s/entries/%s\n' "$(entries_root "${type}")" "${id}"
}

meta_get() {
  local type="$1"
  local id="$2"
  local key="$3"
  local meta_file
  meta_file="$(entry_dir "${type}" "${id}")/meta.env"
  [ -f "${meta_file}" ] || return 0
  awk -F= -v wanted="${key}" '$1 == wanted {print substr($0, index($0, "=") + 1); exit}' "${meta_file}"
}

format_epoch() {
  local epoch="$1"
  date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
}

store_entry() {
  local type="$1"
  local source="$2"
  local context="$3"
  local input_file="$4"
  local root index_file epoch iso id entry size chunk_count hash

  ensure_layout
  root="$(entries_root "${type}")"
  index_file="$(index_path "${type}")"
  epoch="$(date +%s)"
  iso="$(format_epoch "${epoch}")"
  id="$(date +%s%N)-$$-$RANDOM"
  entry="${root}/entries/${id}"
  mkdir -p "${entry}/chunks"

  if [ -s "${input_file}" ]; then
    split -b "${MAX_BLOCK_SIZE}" -d -a 4 --additional-suffix=.bin "${input_file}" "${entry}/chunks/chunk-"
  else
    : >"${entry}/chunks/chunk-0000.bin"
  fi

  size="$(wc -c <"${input_file}" | tr -d ' ')"
  chunk_count="$(find "${entry}/chunks" -maxdepth 1 -type f -name 'chunk-*.bin' | wc -l | tr -d ' ')"
  hash="$(sha256_file "${input_file}")"

  cat >"${entry}/meta.env" <<EOF
type=${type}
created_epoch=${epoch}
created_iso=${iso}
source=$(sanitize_meta_value "${source}")
context=$(sanitize_meta_value "${context}")
size_bytes=${size}
chunk_count=${chunk_count}
sha256=${hash}
EOF

  append_index "${index_file}" "${epoch}"$'\t'"${id}"$'\t'"${size}"$'\t'"${chunk_count}"
  printf '%s\n' "${id}"
}

cat_entry() {
  local type="$1"
  local id="$2"
  local dir chunks
  dir="$(entry_dir "${type}" "${id}")"
  chunks=("${dir}"/chunks/chunk-*.bin)
  [ "${#chunks[@]}" -gt 0 ] || {
    printf 'entry not found: %s/%s\n' "${type}" "${id}" >&2
    return 1
  }
  cat "${chunks[@]}"
}

resolve_id() {
  local type="$1"
  local selector="$2"
  local index_file id
  index_file="$(index_path "${type}")"

  if [[ "${selector}" =~ ^[0-9]+$ ]]; then
    id="$(tac "${index_file}" | awk -F'\t' -v n="${selector}" 'NR == n {print $2; exit}')"
    printf '%s\n' "${id}"
    return
  fi
  printf '%s\n' "${selector}"
}

entry_exists() {
  local type="$1"
  local id="$2"
  [ -n "${id}" ] && [ -d "$(entry_dir "${type}" "${id}")" ]
}

entry_preview() {
  local type="$1"
  local id="$2"
  local first_chunk
  first_chunk="$(entry_dir "${type}" "${id}")/chunks/chunk-0000.bin"
  [ -f "${first_chunk}" ] || {
    printf '<missing>'
    return
  }
  head -c 72 "${first_chunk}" \
    | LC_ALL=C tr '\r\n\t' '   ' \
    | LC_ALL=C tr -c '[:print:]' '.'
}

list_entries() {
  local type="$1"
  local limit="${2:-20}"
  local index_file n epoch id size _chunk_count when source context preview
  ensure_layout
  index_file="$(index_path "${type}")"

  if [ ! -s "${index_file}" ]; then
    printf 'No %s history entries.\n' "${type}"
    return 0
  fi

  n=0
  while IFS=$'\t' read -r epoch id size _chunk_count; do
    n=$((n + 1))
    when="$(format_epoch "${epoch}")"
    source="$(meta_get "${type}" "${id}" source)"
    context="$(meta_get "${type}" "${id}" context)"
    preview="$(entry_preview "${type}" "${id}")"
    printf '%3d | %s | %9s B | %s | %s | %s\n' "${n}" "${when}" "${size}" "${source:-unknown}" "${id}" "${preview}"
    [ -n "${context}" ] && printf '      context: %s\n' "${context}"
  done < <(tac "${index_file}" | head -n "${limit}")
}

count_entries() {
  local type="$1"
  local index_file
  ensure_layout
  index_file="$(index_path "${type}")"
  wc -l <"${index_file}" | tr -d ' '
}

clipboard_write_file() {
  local file="$1"
  if command -v wl-copy >/dev/null 2>&1; then
    wl-copy <"${file}"
    return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -in <"${file}"
    return 0
  fi
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy <"${file}"
    return 0
  fi
  if command -v clip.exe >/dev/null 2>&1; then
    clip.exe <"${file}"
    return 0
  fi
  return 1
}

clipboard_read_file() {
  local file="$1"
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste >"${file}"
    return 0
  fi
  if command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -out >"${file}"
    return 0
  fi
  if command -v pbpaste >/dev/null 2>&1; then
    pbpaste >"${file}"
    return 0
  fi
  return 1
}

store_clipboard() {
  local source="stdin"
  local context=""
  local tmp id

  while [ $# -gt 0 ]; do
    case "$1" in
      --source)
        source="${2:-stdin}"
        shift 2
        ;;
      --context)
        context="${2:-}"
        shift 2
        ;;
      *)
        printf 'unknown option for store-clipboard: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  tmp="$(mktemp)"
  cat >"${tmp}"
  if [ ! -s "${tmp}" ]; then
    rm -f "${tmp}"
    printf 'clipboard input empty, nothing stored\n' >&2
    return 1
  fi

  id="$(store_entry clipboard "${source}" "${context}" "${tmp}")"
  tmux load-buffer -w -b "clip-${id}" "${tmp}" >/dev/null 2>&1 || true
  clipboard_write_file "${tmp}" >/dev/null 2>&1 || true
  rm -f "${tmp}"
  printf '%s\n' "${id}"
}

import_clipboard() {
  local source="system"
  local tmp id

  while [ $# -gt 0 ]; do
    case "$1" in
      --source)
        source="${2:-system}"
        shift 2
        ;;
      *)
        printf 'unknown option for import-clipboard: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  tmp="$(mktemp)"
  if ! clipboard_read_file "${tmp}"; then
    rm -f "${tmp}"
    printf 'no supported system clipboard reader found\n' >&2
    return 1
  fi
  if [ ! -s "${tmp}" ]; then
    rm -f "${tmp}"
    printf 'system clipboard empty, nothing stored\n' >&2
    return 1
  fi

  id="$(store_entry clipboard "${source}" "imported-from-system" "${tmp}")"
  tmux load-buffer -w -b "clip-${id}" "${tmp}" >/dev/null 2>&1 || true
  rm -f "${tmp}"
  printf '%s\n' "${id}"
}

restore_clipboard() {
  local selector="${1:-}"
  local id tmp
  [ -n "${selector}" ] || {
    printf 'restore-clipboard requires an entry number or ID\n' >&2
    return 1
  }

  id="$(resolve_id clipboard "${selector}")"
  entry_exists clipboard "${id}" || {
    printf 'clipboard entry not found: %s\n' "${selector}" >&2
    return 1
  }

  tmp="$(mktemp)"
  cat_entry clipboard "${id}" >"${tmp}"
  tmux load-buffer -w -b "clip-${id}" "${tmp}" >/dev/null 2>&1 || true
  clipboard_write_file "${tmp}" >/dev/null 2>&1 || true
  rm -f "${tmp}"
  printf 'restored %s\n' "${id}"
}

clear_entries() {
  local type="$1"
  local root index_file
  ensure_layout
  root="$(entries_root "${type}")"
  index_file="$(index_path "${type}")"

  rm -rf "${root}/entries"
  mkdir -p "${root}/entries"
  : >"${index_file}"

  if [ "${type}" = "clipboard" ]; then
    tmux delete-buffer -a >/dev/null 2>&1 || true
  else
    rm -rf "${PANE_ROOT}/last"
    mkdir -p "${PANE_ROOT}/last"
  fi
}

capture_pane_once() {
  local pane_id="$1"
  local source="$2"
  local context="$3"
  local tmp hash hash_file id size

  tmp="$(mktemp)"
  if ! tmux capture-pane -epJ -S - -t "${pane_id}" >"${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    return 1
  fi

  size="$(wc -c <"${tmp}" | tr -d ' ')"
  if [ "${size}" -eq 0 ]; then
    rm -f "${tmp}"
    return 2
  fi

  hash="$(sha256_file "${tmp}")"
  hash_file="${PANE_ROOT}/last/${pane_id}.sha256"
  if [ -f "${hash_file}" ] && [ "$(cat "${hash_file}")" = "${hash}" ]; then
    rm -f "${tmp}"
    return 3
  fi

  id="$(store_entry panes "${source}" "${context}" "${tmp}")"
  printf '%s\n' "${hash}" >"${hash_file}"
  rm -f "${tmp}"
  printf '%s\n' "${id}"
}

save_panes() {
  local source="auto"
  local total=0
  local saved=0
  local session window_index window_name pane_index pane_id pane_title pane_path

  while [ $# -gt 0 ]; do
    case "$1" in
      --source)
        source="${2:-auto}"
        shift 2
        ;;
      *)
        printf 'unknown option for save-panes: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  ensure_layout
  if ! tmux list-panes -a >/dev/null 2>&1; then
    printf 'no tmux server available for pane capture\n' >&2
    return 1
  fi

  while IFS=$'\t' read -r session window_index window_name pane_index pane_id pane_title pane_path; do
    total=$((total + 1))
    if capture_pane_once \
      "${pane_id}" \
      "${source}:${session}:${window_index}.${pane_index}" \
      "pane=${pane_id} window=${window_name} title=${pane_title} cwd=${pane_path}" >/dev/null; then
      saved=$((saved + 1))
    fi
  done < <(tmux list-panes -a -F '#{session_name}'$'\t''#{window_index}'$'\t''#{window_name}'$'\t''#{pane_index}'$'\t''#{pane_id}'$'\t''#{pane_title}'$'\t''#{pane_current_path}')

  printf 'pane snapshots saved: %s/%s\n' "${saved}" "${total}"
}

show_pane() {
  local selector="${1:-}"
  local id
  [ -n "${selector}" ] || {
    printf 'show-pane requires an entry number or ID\n' >&2
    return 1
  }

  id="$(resolve_id panes "${selector}")"
  entry_exists panes "${id}" || {
    printf 'pane snapshot not found: %s\n' "${selector}" >&2
    return 1
  }
  cat_entry panes "${id}"
}

browse_panes_menu() {
  local selector id tmp
  clear
  printf 'Pane/PTY snapshot history (newest first)\n\n'
  list_entries panes 30
  printf '\n'
  read -r -p "Open snapshot number or ID (empty to go back): " selector
  [ -n "${selector}" ] || return 0

  id="$(resolve_id panes "${selector}")"
  entry_exists panes "${id}" || {
    printf 'invalid selection: %s\n' "${selector}"
    read -r -p 'Press Enter to continue... ' _
    return 0
  }

  tmp="$(mktemp)"
  cat_entry panes "${id}" >"${tmp}"
  less -R "${tmp}"
  rm -f "${tmp}"
}

browse_clipboard_menu() {
  local selector
  clear
  printf 'Clipboard history (newest first)\n\n'
  list_entries clipboard 30
  printf '\n'
  read -r -p "Restore entry number or ID (empty to go back): " selector
  [ -n "${selector}" ] || return 0
  if restore_clipboard "${selector}" >/dev/null; then
    printf 'clipboard restored\n'
  else
    printf 'failed to restore selection: %s\n' "${selector}"
  fi
  read -r -p 'Press Enter to continue... ' _
}

menu() {
  local choice
  while true; do
    clear
    cat <<'EOF'
Tmux History Console

1) Browse pane/PTY snapshots
2) Browse clipboard history and restore
3) Snapshot all panes now
4) Import current system clipboard into history
5) Clear clipboard history (manual clear)
6) Clear pane history (manual clear)
q) Quit
EOF
    printf '\n'
    read -r -p 'Select: ' choice
    case "${choice}" in
      1) browse_panes_menu ;;
      2) browse_clipboard_menu ;;
      3)
        save_panes --source manual
        read -r -p 'Press Enter to continue... ' _
        ;;
      4)
        import_clipboard --source menu || true
        read -r -p 'Press Enter to continue... ' _
        ;;
      5)
        clear_entries clipboard
        printf 'clipboard history cleared\n'
        read -r -p 'Press Enter to continue... ' _
        ;;
      6)
        clear_entries panes
        printf 'pane history cleared\n'
        read -r -p 'Press Enter to continue... ' _
        ;;
      q|Q) break ;;
      *)
        printf 'unknown option: %s\n' "${choice}"
        read -r -p 'Press Enter to continue... ' _
        ;;
    esac
  done
}

daemon_pid_file() {
  local server_pid
  server_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || printf 'unknown')"
  printf '%s/pane-daemon-%s.pid\n' "${PANE_ROOT}" "${server_pid}"
}

pane_daemon_loop() {
  local interval="${1:-120}"
  while true; do
    "${BASH_SOURCE[0]}" save-panes --source daemon >/dev/null 2>&1 || true
    sleep "${interval}"
  done
}

pane_daemon_start() {
  local interval="${1:-120}"
  local pid_file pid
  ensure_layout
  pid_file="$(daemon_pid_file)"
  if [ -f "${pid_file}" ]; then
    pid="$(cat "${pid_file}")"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi

  nohup "${BASH_SOURCE[0]}" pane-daemon-loop "${interval}" >/dev/null 2>&1 &
  pid="$!"
  printf '%s\n' "${pid}" >"${pid_file}"
}

pane_daemon_stop() {
  local pid_file pid
  ensure_layout
  pid_file="$(daemon_pid_file)"
  [ -f "${pid_file}" ] || return 0
  pid="$(cat "${pid_file}")"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${pid_file}"
}

main() {
  ensure_layout
  local cmd="${1:-}"
  [ -n "${cmd}" ] || {
    usage
    return 1
  }
  shift || true

  case "${cmd}" in
    store-clipboard) store_clipboard "$@" ;;
    import-clipboard) import_clipboard "$@" ;;
    restore-clipboard) restore_clipboard "$@" ;;
    list-clipboard) list_entries clipboard "${1:-20}" ;;
    clear-clipboard) clear_entries clipboard ;;

    save-panes) save_panes "$@" ;;
    list-panes) list_entries panes "${1:-20}" ;;
    show-pane) show_pane "$@" ;;
    clear-panes) clear_entries panes ;;

    count)
      case "${1:-}" in
        clipboard|panes) count_entries "$1" ;;
        *)
          printf 'count requires clipboard|panes\n' >&2
          return 1
          ;;
      esac
      ;;
    menu) menu ;;

    pane-daemon-start) pane_daemon_start "${1:-120}" ;;
    pane-daemon-stop) pane_daemon_stop ;;
    pane-daemon-loop) pane_daemon_loop "${1:-120}" ;;
    *)
      usage
      return 1
      ;;
  esac
}

main "$@"
