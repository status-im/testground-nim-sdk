<h3 align="center"><a href="https://github.com/testground/testground/">Testground</a> SDK for <a href="https://nim-lang.org/">Nim</a></h3>

Quickstart:
```sh
# Assuming testground is correctly setup
git clone https://github.com/status-im/testground-nim-sdk.git
cd testground-nim-sdk
testground plan import --name demo --from examples/simple_tcp_ping
testground run single --plan=demo --testcase=simple_tcp_ping --runner=local:docker --builder=docker:generic --instances=2
```


This is not stable in any shape or form. Features:
- [X] Basic communication with testground
- [X] Logging
- [X] Network configuration
- [X] Signal, barrier
- [X] PubSub
- [ ] Run configuration
- [ ] Multiple scenario in a single plan
- [ ] ..
