# Astaria Contracts Setup

Astaria runs on [Foundry](https://github.com/foundry-rs/foundry).

To install contract dependencies, run:

```sh
yarn
forge install
git submodule
```

Tests are located in src/test. To run tests, run:

```sh
forge test --ffi
```

To target integration tests following common use paths, run:

```sh
forge test --ffi --match-contract AstariaTest
```

To target tests following disallowed behavior, run:

```sh
forge test --ffi --match-contract RevertTesting
```