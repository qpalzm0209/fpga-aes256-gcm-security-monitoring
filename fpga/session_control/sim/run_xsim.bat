@echo off
setlocal
if not defined VIVADO_BIN goto use_path
set "XVLOG=%VIVADO_BIN%\xvlog.bat"
set "XELAB=%VIVADO_BIN%\xelab.bat"
set "XSIM=%VIVADO_BIN%\xsim.bat"
if not exist "%XVLOG%" exit /b 1
goto run

:use_path
where xvlog.bat >nul 2>&1 || (
    echo Set VIVADO_BIN to the Vivado 2025.2 bin directory. 1>&2
    exit /b 1
)
set "XVLOG=xvlog.bat"
set "XELAB=xelab.bat"
set "XSIM=xsim.bat"

:run
call "%XVLOG%" -sv -d TX_V1_WRAPPER --work tx_session_work ..\..\AES_GCM_TX\vivado\rtl\session\aes_session_key_regs.sv ..\..\AES_GCM_TX\vivado\rtl\session\aes_session_key_regs_bd.v tb_aes_session_key_regs.sv || exit /b 1
call "%XELAB%" tx_session_work.tb_aes_session_key_regs -s tb_aes_session_key_regs_tx_sim || exit /b 1
call "%XSIM%" tb_aes_session_key_regs_tx_sim -runall || exit /b 1

call "%XVLOG%" -sv --work rx_session_work ..\..\AES_GCM_RX\vivado\rtl\session\aes_session_key_regs.sv tb_aes_session_key_regs.sv || exit /b 1
call "%XELAB%" rx_session_work.tb_aes_session_key_regs -s tb_aes_session_key_regs_rx_sim || exit /b 1
call "%XSIM%" tb_aes_session_key_regs_rx_sim -runall || exit /b 1
