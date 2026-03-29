# Build stage
FROM elixir:1.19-otp-28-slim AS builder

RUN apt-get update && apt-get install -y git openssh-client && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY elixir/ ./
RUN mix local.hex --force && mix local.rebar --force
RUN MIX_ENV=prod mix deps.get --only prod
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release symphony

# Runtime stage
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y libstdc++6 openssl libncurses5 locales git && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen && \
    rm -rf /var/lib/apt/lists/*

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app
RUN mkdir -p /workspaces

COPY --from=builder /app/_build/prod/rel/symphony ./

EXPOSE 4000 4369 9100-9200

CMD ["bin/symphony", "start"]
