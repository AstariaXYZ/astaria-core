import os


while True:
    output = os.popen("forge test --ffi --fork-url https://eth-mainnet.alchemyapi.io/v2/crm65ztnFlqvr08HoTDXF_Z_8wF0Pt-j").read()
    if "429" not in output:
        print(output)
        break