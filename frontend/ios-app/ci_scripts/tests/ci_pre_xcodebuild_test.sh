#!/bin/sh
set -eu

script_path=${1:?"usage: $0 SCRIPT_PATH [--probe-already-imported]"}
mode=${2:-test}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/ci_pre_xcodebuild_test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

mkdir -p "$test_root/bin"

cat > "$test_root/bin/xcodebuild" <<'MOCK'
#!/bin/sh
set -eu

printf '%s\n' "$*" >> "$MOCK_LOG"

case "$1" in
    -showComponent)
        exit "${MOCK_SHOW_STATUS:-1}"
        ;;
    -downloadComponent)
        case "${MOCK_DOWNLOAD_RESULT:-success}" in
            success)
                echo "Metal Toolchain downloaded."
                exit 0
                ;;
            already-imported)
                echo "xcodebuild: error: Metal Toolchain is already imported at /mock/MetalToolchain.exportedBundle" >&2
                exit 70
                ;;
            failure)
                echo "xcodebuild: error: simulated download failure" >&2
                exit 70
                ;;
        esac
        ;;
esac

echo "unexpected xcodebuild arguments: $*" >&2
exit 64
MOCK

cat > "$test_root/bin/sleep" <<'MOCK'
#!/bin/sh
set -eu
printf 'sleep %s\n' "$*" >> "$MOCK_LOG"
MOCK

chmod +x "$test_root/bin/xcodebuild" "$test_root/bin/sleep"

run_script() {
    show_status=$1
    download_result=$2
    log_path=$3

    set +e
    RUN_OUTPUT=$(
        PATH="$test_root/bin:$PATH" \
        MOCK_LOG="$log_path" \
        MOCK_SHOW_STATUS="$show_status" \
        MOCK_DOWNLOAD_RESULT="$download_result" \
        "$script_path" 2>&1
    )
    RUN_STATUS=$?
    set -e
}

count_downloads() {
    log_path=$1
    awk '$1 == "-downloadComponent" { count += 1 } END { print count + 0 }' "$log_path"
}

if [ "$mode" = "--probe-already-imported" ]; then
    probe_log="$test_root/probe.log"
    : > "$probe_log"
    run_script 1 already-imported "$probe_log"
    printf 'status=%s downloads=%s\n' "$RUN_STATUS" "$(count_downloads "$probe_log")"
    printf '%s\n' "$RUN_OUTPUT"
    exit "$RUN_STATUS"
fi

assert_case() {
    name=$1
    show_status=$2
    download_result=$3
    expected_status=$4
    expected_downloads=$5
    expected_text=$6
    log_path="$test_root/$name.log"
    : > "$log_path"

    run_script "$show_status" "$download_result" "$log_path"
    downloads=$(count_downloads "$log_path")

    if [ "$RUN_STATUS" -ne "$expected_status" ]; then
        printf 'FAIL %s: expected status %s, got %s\n%s\n' \
            "$name" "$expected_status" "$RUN_STATUS" "$RUN_OUTPUT" >&2
        exit 1
    fi
    if [ "$downloads" -ne "$expected_downloads" ]; then
        printf 'FAIL %s: expected %s downloads, got %s\n%s\n' \
            "$name" "$expected_downloads" "$downloads" "$RUN_OUTPUT" >&2
        exit 1
    fi
    case "$RUN_OUTPUT" in
        *"$expected_text"*) ;;
        *)
            printf 'FAIL %s: missing output %s\n%s\n' \
                "$name" "$expected_text" "$RUN_OUTPUT" >&2
            exit 1
            ;;
    esac

    printf 'PASS %s status=%s downloads=%s\n' \
        "$name" "$RUN_STATUS" "$downloads"
}

assert_case installed 0 failure 0 0 "Metal Toolchain is already available."
assert_case downloaded 1 success 0 1 "Metal Toolchain downloaded."
assert_case concurrent-import 1 already-imported 0 1 "Metal Toolchain became available during download."
assert_case persistent-failure 1 failure 1 3 "Failed to install the Metal Toolchain after 3 attempts."
