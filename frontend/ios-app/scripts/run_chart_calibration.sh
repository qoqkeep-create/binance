#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Run one Trade Tool/Binance chart calibration UI test on a trusted USB device.

Usage:
  IOS_DEVICE_UDID=<udid> frontend/ios-app/scripts/run_chart_calibration.sh [test-method]
  frontend/ios-app/scripts/run_chart_calibration.sh --list

The default test is testCaptureBinancePreparedChartState. Result bundles and
exported attachments are written below /tmp unless CALIBRATION_OUTPUT_ROOT is
set. Trade Tool builds use Debug-Dev-B by default and reuse Xcode's per-project
DerivedData cache instead of creating a new cache for every test run.
EOF
}

list_tests() {
    cat <<'EOF'
testCaptureBinancePreparedChartState
testRecoverBinancePublicChartDetail
testRecoverBinanceBTCUSDCDetailFromMarketList
testCaptureBinancePrimaryIndicatorReferences
testCaptureBinanceRemainingPanelIndicatorReferences
testRestoreBinancePanelReferenceBaseline
testDisableBinanceATRInterruptedReference
testNormalizeBinancePanelReferenceBaseline
testCaptureBinanceIndicatorPicker
testCaptureBinanceATRAndMarketPanelIndicatorReferences
testCaptureBinanceAllPanelIndicatorReferencesViaPicker
testCaptureBinanceIndicatorSettings
testCaptureBinanceIndicatorParameterSettings
testOpenBinanceIndicatorParameterList
testCaptureBinancePrimaryIndicatorParameterDetails
testCaptureBinancePanelIndicatorParameterDetails
testCaptureBinanceCandleGeometryZoomSequence
testCaptureBinanceCurrentPriceReferenceStates
testCaptureBinanceCrosshairTapToggleReference
testCaptureBinanceLatestFutureBlankLimit
testCaptureTradeToolPreparedChartState
testCaptureTradeToolChartOnlyDetail
testCaptureTradeToolPanelActivationOrder
testCaptureTradeToolIndicatorSettingsShortcut
testCaptureTradeToolQuickSwitcherFlow
testCaptureTradeToolPrimaryIndicatorReferences
testCaptureTradeToolRemainingPanelIndicatorReferences
testCaptureTradeToolTechnicalPanelIndicatorReferences
testVerifyTradeToolProductionOpenInterest
testCaptureTradeToolCandleGeometryZoomSequence
testCaptureTradeToolCurrentPriceReferenceStates
testCaptureTradeToolCrosshairTapToggleReference
testCaptureTradeToolLatestFutureBlankLimit
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --list)
        list_tests
        exit 0
        ;;
esac

if [[ -z "${IOS_DEVICE_UDID:-}" ]]; then
    usage >&2
    printf '\nMissing IOS_DEVICE_UDID. Discover it with: xcrun devicectl list devices\n' >&2
    exit 64
fi

test_method="${1:-testCaptureBinancePreparedChartState}"
case "$test_method" in
    */*) only_testing="$test_method" ;;
    *) only_testing="TradeToolChartCalibrationUITests/ChartCalibrationUITests/$test_method" ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_dir/../../.." && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
output_root="${CALIBRATION_OUTPUT_ROOT:-/tmp/trade-tool-chart-calibration-$timestamp}"
result_bundle_path="${output_root}.xcresult"
attachments_path="${output_root}-attachments"
lock_state_path="${output_root}-lock-state.json"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
configuration="${CALIBRATION_CONFIGURATION:-Debug-Dev-B}"

case "$output_root" in
    /tmp/*|/private/tmp/*|/private/var/folders/*) ;;
    *)
        printf 'CALIBRATION_OUTPUT_ROOT must be inside a temporary directory.\n' >&2
        exit 64
        ;;
esac

DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun devicectl device info lockState \
    --device "$IOS_DEVICE_UDID" \
    --timeout 5 \
    --json-output "$lock_state_path" \
    --quiet
passcode_required="$(/usr/bin/plutil \
    -extract result.passcodeRequired raw \
    -o - \
    "$lock_state_path")"
if [[ "$passcode_required" != "false" ]]; then
    printf 'Unlock the iPhone and keep it awake before running calibration.\n' >&2
    exit 69
fi

printf 'Test: %s\nConfiguration: %s\nDevice: %s\n' \
    "$only_testing" "$configuration" "$IOS_DEVICE_UDID"

test_status=0
DEVELOPER_DIR="$developer_dir" /usr/bin/xcodebuild test -quiet \
    -allowProvisioningUpdates \
    -project "$repository_root/frontend/ios-app/TradeTool.xcodeproj" \
    -scheme "TradeTool Chart Calibration" \
    -configuration "$configuration" \
    -destination "platform=iOS,id=$IOS_DEVICE_UDID" \
    -resultBundlePath "$result_bundle_path" \
    -only-testing:"$only_testing" || test_status=$?

attachments_status=0
if [[ -d "$result_bundle_path" ]]; then
    DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun xcresulttool export attachments \
        --path "$result_bundle_path" \
        --output-path "$attachments_path" || attachments_status=$?
else
    printf 'Result bundle was not created; no attachments can be exported.\n' >&2
    attachments_status=66
fi

printf '\nResult bundle: %s\nAttachments: %s\n' \
    "$result_bundle_path" "$attachments_path"

if [[ "$test_status" -ne 0 ]]; then
    exit "$test_status"
fi
exit "$attachments_status"
