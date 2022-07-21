import std/strutils, testground_sdk, chronos, stew/byteutils

testground(client):
  let
    myId = await client.signalAndWait("setup", client.testInstanceCount)
    myIp = client.testSubnet.split('.')[0..1].join(".") & ".1." & $myId
    serverIp = client.testSubnet.split('.')[0..1].join(".") & ".1.1"
  await client.updateNetworkParameter(
    NetworkConf(
      network: "default",
      ipv4: some myIp & "/24",
      enable: true,
      callback_state: "network_setup",
      callback_target: some client.testInstanceCount,
      routing_policy: "accept_all",
    )
  )

  await client.waitForBarrier("network_setup", client.testInstanceCount)

  const payload = "Hello playground!"
  if myId == 1: # server
    let
      server = createStreamServer(initTAddress(myIp & ":5050"), flags = {ReuseAddr})
      connection = await server.accept()

    doAssert (await connection.write(payload.toBytes())) == payload.len
    connection.close()

  else: # client
    let connection = await connect(initTAddress(serverIp & ":5050"))
    var buffer: array[payload.len, byte]

    await connection.readExactly(addr buffer[0], payload.len)
    connection.close()
    doAssert string.fromBytes(buffer) == payload
  client.recordMessage("Hourray " & $myId & "!")
