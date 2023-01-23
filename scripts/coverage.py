import json
import subprocess

coverage_contracts = ["IAstariaRouter", "ClearingHouse", "ICollateralToken", "ILienToken", "IPublicVault", "IVaultImplementation", "WithdrawProxy"]
excluded_parent_contracts = ["AuthInitializable", "Initializable", "AmountDeriver", "Clone", "IERC1155", "IERC721Receiver", "ERC721", "ZoneInterface", "IERC4626"]

tests = subprocess.run(["forge", "test", "--ffi", "--no-match-contract", "ForkedTest", "-vvvvv"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)

with open("coverage.txt", "w") as file:
    pass

excluded_parent_fns = []
for contract in excluded_parent_contracts:
    with open("out/" + contract + ".sol/" + contract + ".json") as file:
        abi = json.load(file)
    for fn in abi["methodIdentifiers"].keys():
        excluded_parent_fns.append(fn.split("(")[0])\

# remove duplicates
excluded_parent_fns = list(dict.fromkeys(excluded_parent_fns))

for contract in coverage_contracts:
    with open("out/" + contract + ".sol/" + contract + ".json") as file:
        abi = json.load(file)
    covered_fns = abi["methodIdentifiers"]
    coverage = len(covered_fns)
    excluded_fns = 0
    uncovered_fns = []
    for fn in covered_fns.keys():
        fn_name = fn.split("(")[0]
        if fn_name in excluded_parent_fns or fn_name.startswith("get") or fn_name.startswith("is") or fn_name == fn_name.upper():
            excluded_fns += 1
        elif fn_name not in tests.stdout.decode("utf-8"):
            uncovered_fns.append(fn_name)
            coverage -= 1
    # store the contents of uncovered_fns in a text file
    with open("coverage.txt", "a") as file:
        file.write("\n" + contract + ": ")
        for fn_name in uncovered_fns:
            file.write(fn_name + ", ")
    print(contract + ": " + str(coverage - excluded_fns) + "/" + str(len(covered_fns) - excluded_fns))







