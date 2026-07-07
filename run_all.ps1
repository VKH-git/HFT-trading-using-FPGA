# run_all.ps1  --  Master regression script for HFT Trading System
# Compiles and runs every testbench, collects pass/fail, prints final summary.
# Usage: cd hft_trading_system; .\run_all.ps1

$IVERILOG = "C:\iverilog\bin\iverilog.exe"
$VVP      = "C:\iverilog\bin\vvp.exe"

$RTL = @(
    "rtl\uart_rx.sv",
    "rtl\uart_tx.sv",
    "rtl\packet_assembler.sv",
    "rtl\order_book.sv",
    "rtl\strategy_vwap.sv",
    "rtl\strategy_momentum.sv",
    "rtl\strategy_core.sv",
    "rtl\risk_gate.sv",
    "rtl\pnl_engine.sv",
    "rtl\order_serializer.sv",
    "rtl\trading_top.sv"
)

# Each entry: [label, vvp_output, tb_file(s)]
$TESTS = @(
    @{ Label="UART Loopback";      VVP="sim\tb_uart_loopback.vvp";    TB=@("sim\tb_uart_loopback.sv") },
    @{ Label="Packet Assembler";   VVP="sim\tb_packet_assembler.vvp"; TB=@("sim\tb_packet_assembler.sv") },
    @{ Label="Order Book";         VVP="sim\tb_order_book.vvp";       TB=@("sim\tb_order_book.sv") },
    @{ Label="Strategy VWAP";      VVP="sim\tb_strategy_vwap.vvp";    TB=@("sim\tb_strategy_vwap.sv") },
    @{ Label="Strategy Core";      VVP="sim\tb_strategy_core.vvp";    TB=@("sim\tb_strategy_core.sv") },
    @{ Label="Risk + PnL Engine";  VVP="sim\tb_risk_pnl.vvp";         TB=@("sim\tb_risk_pnl.sv") },
    @{ Label="Order Serializer";   VVP="sim\tb_order_serializer.vvp"; TB=@("sim\tb_order_serializer.sv") },
    @{ Label="System (SYS1-SYS7)"; VVP="sim\tb_system.vvp";           TB=@("sim\tb_system.sv") },
    @{ Label="Latency Measure";    VVP="sim\tb_latency.vvp";           TB=@("sim\tb_latency.sv") }
)

$totalPassed = 0
$totalFailed = 0
$results = @()

Write-Host ""
Write-Host "============================================================"
Write-Host "   HFT Trading System -- Full Regression Run"
Write-Host "============================================================"
Write-Host ""

foreach ($t in $TESTS) {
    Write-Host ">>> Compiling: $($t.Label)..."

    $compileArgs = @("-g2012", "-o", $t.VVP) + $RTL + $t.TB
    $compileOut  = & $IVERILOG @compileArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    [COMPILE ERROR]"
        Write-Host $compileOut
        $results += [PSCustomObject]@{ Label=$t.Label; Passed=0; Failed=1; Status="COMPILE ERROR" }
        $totalFailed++
        continue
    }

    Write-Host "    Compile OK -- Running..."
    $simOut = & $VVP $t.VVP 2>&1

    # Parse pass/fail from standard output
    $passed = 0; $failed = 0
    foreach ($line in ($simOut -split "`n")) {
        if ($line -match "Passed\s*:\s*(\d+)")  { $passed = [int]$Matches[1] }
        if ($line -match "Failed\s*:\s*(\d+)")  { $failed = [int]$Matches[1] }
        # Latency bench has no pass/fail counters — use PASS assertions
        if ($line -match "PASS\s+Pipeline")    { $passed++ }
        if ($line -match "PASS\s+Total")       { $passed++ }
        if ($line -match "FAIL\s+Pipeline")    { $failed++ }
        if ($line -match "FAIL\s+Total")       { $failed++ }
    }

    $status = if ($failed -eq 0) { "PASS" } else { "FAIL" }
    $totalPassed += $passed
    $totalFailed += $failed

    $results += [PSCustomObject]@{
        Label  = $t.Label
        Passed = $passed
        Failed = $failed
        Status = $status
    }

    $icon = if ($status -eq "PASS") { "[OK]" } else { "[!!]" }
    Write-Host "    $icon  Passed=$passed  Failed=$failed"
    Write-Host ""
}

Write-Host "============================================================"
Write-Host "   RESULTS SUMMARY"
Write-Host "============================================================"
$results | Format-Table -AutoSize Label, Passed, Failed, Status
Write-Host "------------------------------------------------------------"
Write-Host ("   TOTAL PASSED : " + $totalPassed)
Write-Host ("   TOTAL FAILED : " + $totalFailed)
if ($totalFailed -eq 0) {
    Write-Host "   RESULT       : ALL TESTS PASSED"
} else {
    Write-Host "   RESULT       : *** FAILURES DETECTED ***"
}
Write-Host "============================================================"
Write-Host ""
