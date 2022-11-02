import
  std/[tables, parseutils, strutils, os, sequtils, json],
  chronos, websock/websock, chronicles, stew/byteutils

# workaround https://github.com/status-im/nim-serialization/issues/43
from serialization import serializedFieldName
from json_serialization import Reader, init, readValue, handleReadException
import json_serialization/std/options

export sequtils, strutils, os, tables
export chronos, options, chronicles, websock
export json_serialization

type
  Client* = ref object
    requestId: int
    requests: Table[string, Future[Response]]
    subbed: Table[string, AsyncQueue[JsonNode]]
    connection: WSSession
    testRun: string
    testPlan: string
    testCase: string
    testInstanceCount: int
    testGroupId: string
    testHostname: string
    testSubnet: string

  LinkShape* = object
    latency: int
    jitter: int
    bandwidth: int
    loss: float
    corrupt: float
    corrupt_corr: float
    reorder: float
    reorder_corr: float
    duplicate: float
    duplicate_corr: float

  NetworkConf* = object
    network: string
    ipv4 {.serializedFieldName: "IPv4".}: Option[string]
    ipv6 {.serializedFieldName: "IPv6".}: Option[string]
    enable: bool
    default: LinkShape
    callback_state: string
    callback_target: Option[int]
    routing_policy: string

  SignalEntryRequest* = object
    state: string

  SignalEntryResponse* = object
    seq: int

  BarrierRequest* = object
    state: string
    target: int

  Subscribe* = object
    topic: string

  PublishRequest* = object
    topic: string
    event {.serializedFieldName: "payload".}: Option[Event]
    networkConf {.serializedFieldName: "payload".}: Option[NetworkConf]
    payload: Option[string]

  Event* = object
    #workaround https://github.com/status-im/nim-json-serialization/pull/50
    dummy: string
    success_event: Option[SuccessEvent]
    message_event: Option[MessageEvent]

  StdoutEvent = object
    event: Event

  MessageEvent* = object
    message: string

  SuccessEvent* = object
    group: string

  Request* = object
    id: string
    signal_entry: Option[SignalEntryRequest]
    publish: Option[PublishRequest]
    barrier: Option[BarrierRequest]
    subscribe: Option[Subscribe]

  Response* = object
    id: string
    signal_entry: Option[SignalEntryResponse]
    subscribe: Option[JsonNode]
    error: string

proc request(c: Client, r: Request): Future[Response] {.async.} =
  let retFut = newFuture[Response]("sendRequest")
  var r2 = r

  r2.id = $c.requestId
  c.requestId.inc
  c.requests[r2.id] = retFut
  await c.connection.send(r2.toJson())

  #echo "sending:", r2.toJson()

  return await retFut

proc getContext(c: Client): string =
  "run:" & c.testRun & ":plan:" & c.testPlan & ":case:" & c.testCase
proc getState(c: Client, state: string): string =
  c.getContext & ":states:" & state

proc signal*(c: Client, state: string): Future[int] {.async.} =
  ## Signal that we reached `state`, returns how many times
  ## `state` was reached
  let r = await c.request(Request(
    signal_entry: some(SignalEntryRequest(
      state: c.getState(state)
    ))
  ))

  return r.signal_entry.get().seq

proc waitForBarrier*(c: Client, state: string, target: int) {.async.} =
  ## Wait for `state` to be reached `target` times
  discard await c.request(Request(
    barrier: some(BarrierRequest(
      state: c.getState(state),
      target: target
    ))
  ))

proc signalAndWait*(c: Client, state: string, target: int): Future[int] {.async.} =
  ## Signal that we reached `state`, wait for it to be reached `target` times,
  ## and returns how much time it was reached before us
  result = await c.signal(state)
  await c.waitForBarrier(state, target)

proc success(c: Client): Future[int] {.async.} =
  let r = await c.request(Request(
    publish: some(PublishRequest(
      topic: c.getContext() & ":run_events",
      event: some Event(
        success_event: some(SuccessEvent(
          group: c.testGroupId
        ))
      )
    ))
  ))


  echo StdoutEvent(
    event: Event(
      success_event: some(SuccessEvent(
        group: c.testGroupId
      ))
    )
  ).toJson()

proc recordMessage*(c: Client, s: string) =
  ## Record message
  let e = StdoutEvent(
    event: Event(
      message_event: some(MessageEvent(message: s))
    )
  )
  echo e.toJson()

proc waitNetwork*(c: Client) {.async.} =
  ## Wait for network to be setup
  if getEnv("TEST_SIDECAR") == "true":
    await c.waitForBarrier("network-initialized", c.testInstanceCount)

  # magic value
  c.recordMessage("network initialisation successful")

proc updateNetworkParameter*(c: Client, n: NetworkConf) {.async.} =
  let r = await c.request(Request(
    publish: some PublishRequest(
      topic: c.getContext() & ":topics:network:" & c.testHostname,
      networkConf: some n
    )
  ))

proc subscribe*(c: Client, topic: string): AsyncQueue[JsonNode] =
  ## Subscribe to `topic`. Returns a queue that will be filled with each new entry
  let id = c.requestId

  c.requestId.inc
  result = newAsyncQueue[JsonNode](1000)
  c.subbed[$id] = result
  asyncSpawn c.connection.send(Request(
    id: $id,
    subscribe: some Subscribe(
      topic: c.getContext() & ":topics:" & topic
    )
  ).toJson())

proc subscribe*[T](c: Client, topic: string, _: type[T]): AsyncQueue[T] =
  var
    theQueue = c.subscribe(topic)
    resQueue = newAsyncQueue[T](1000)
  proc getter {.async.} =
    mixin decode
    while true:
      let
        elem = await theQueue.popFirst()
        decoded = json_serialization.decode(Json, $elem, T, allowUnknownFields = true)
      resQueue.addLastNoWait(decoded)

  asyncSpawn getter
  resQueue

proc publish*(c: Client, topic, content: string) {.async.} =
  ## Publish `content` to `topic`
  let r = await c.request(Request(
    publish: some PublishRequest(
      topic: c.getContext() & ":topics:" & topic,
      payload: some content
    )
  ))

proc publish*[T](c: Client, topic: string, content: T) {.async.} =
  mixin toJson
  await c.publish(topic, content.toJson())

proc param*[T](c: Client, _: type[T], name: string): T =
  let params = getEnv("TEST_INSTANCE_PARAMS").split("|").mapIt(it.split("=", 2)).mapIt((it[0], it[1])).toTable()

  let param = params[name]

  when T is string:
    param
  elif T is bool:
    param == "true"
  elif T is Ordinal:
    parseInt(param)
  else:
    {.error: "Unsupported type for param".}

proc runner(todo: proc(c: Client): Future[void] {.gcsafe.}) {.async.} =
  let
    c = Client(
      testRun: getEnv("TEST_RUN"),
      testPlan: getEnv("TEST_PLAN"),
      testCase: getEnv("TEST_CASE"),
      testGroupId: getEnv("TEST_GROUP_ID"),
      testHostname: getEnv("HOSTNAME"),
      testSubnet: getEnv("TEST_SUBNET")
    )
  discard parseInt(getEnv("TEST_INSTANCE_COUNT"), c.testInstanceCount)
  let
    serviceHost = if existsEnv("SYNC_SERVICE_HOST"): getEnv("SYNC_SERVICE_HOST") else: "testground-sync-service"
    servicePort = if existsEnv("SYNC_SERVICE_PORT"): getEnv("SYNC_SERVICE_PORT") else: "5050"
    fullWsAddress = serviceHost & ":" & servicePort

  c.connection = await WebSocket.connect(fullWsAddress, "/")

  defer: await c.connection.close()

  proc readLoop {.async.} =
    while true:
      let
        v = string.fromBytes(await c.connection.recvMsg())
        parsed = json_serialization.decode(Json, v, Response, allowUnknownFields = true)

      #echo "got:", v
      if parsed.id in c.requests:
        c.requests[parsed.id].complete(parsed)
      elif parsed.id in c.subbed:
        c.subbed[parsed.id].addLastNoWait(parsed.subscribe.get())
      else:
        echo "Unknown response id!!!", parsed.id

  let
    theTest = todo(c)
    loop = readLoop()

  await theTest or loop
  await theTest.cancelAndWait()
  await loop.cancelAndWait()

template testground*(c: untyped, b: untyped) =
  proc todo(c: Client) {.async.} =
    await c.waitNetwork()
    b

    discard await c.success()

  #for key, val in envPairs():
  #  echo key, ":", val
  waitFor(runner(todo))
