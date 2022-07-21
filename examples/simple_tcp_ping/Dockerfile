FROM nimlang/nim:alpine as builder

# "checkpoint" to avoid installing dependencies every time
# this is optional
RUN nimble install -y "https://github.com/status-im/testground-nim-sdk"
FROM builder

COPY . .
RUN cd plan && nimble install -d && nim c -d:chronicles_log_level=NOTICE main.nim

ENTRYPOINT ["plan/main"]
