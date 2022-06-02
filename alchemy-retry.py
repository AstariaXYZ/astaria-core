import os
from subprocess import run

while True:
    # output = os.popen("forge test --ffi --fork-url https://eth-mainnet.alchemyapi.io/v2/crm65ztnFlqvr08HoTDXF_Z_8wF0Pt-j").read()
    output = Popen("forge test --ffi --fork-url https://eth-mainnet.alchemyapi.io/v2/crm65ztnFlqvr08HoTDXF_Z_8wF0Pt-j").returncode
    if "The application panicked" not in output:
        print(output)
        print("AAAAAAA")
        print(output[-20:])
        break
    print("failed")