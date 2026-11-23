# GitKanban relay

Live updates for Tasks / GitKanban boards on GitHub and GitLab. The provider calls this Worker
when someone pushes; the Worker tells the connected apps which paths changed, and they reload
just that.

It sees repo names and file paths. It never sees file contents or your git token. Per channel it
stores the repo's name, the channel's two secrets, the random id of the app install that registered
it, and when; it does not store the paths it relays.

The GitKittie relay is deployed at `https://gitkanban-relay.vandipyan.workers.dev`, and the apps
offer that address by default. It reaches apps that are open; a closed app is not woken.

## Who can register

Only GitKittie clients (Tasks, and any other app of the family) can register a channel, and there
is nothing to set up for it. Each install makes its own random id and sends it with a hash that
ties the id, the time and the request to the client family. The relay recomputes the hash and
accepts the registration when it matches, so every client works with every relay.

The value the hash is keyed with is built into the apps and into this relay's source
(`CLIENT_FAMILY`). It is not a secret: it stops anyone who merely knows the relay's address, not
someone who reads the app or this code. The random id is kept with each channel, so installs can
be told apart later (a cap or a block per id is not built).

## Deploy

```sh
cd apps/gitkanban-relay
npx wrangler login      # once
npm run deploy          # prints the Worker's address
```

Then, in the app: open a board on a GitHub or GitLab repo → ⋯ → **Live Updates…** → paste the
address → **Turn On**. That adds a push webhook to the repo and commits `.gitkanban/relay.json`,
which is how your other devices find the channel. Your account needs admin access to the repo on
GitHub, or the Maintainer role (and a token with the `api` scope) on GitLab.

## Check a deployment

```sh
RELAY_URL=https://<your-worker-address> npm run e2e
```

See [AGENTS.md](./AGENTS.md) for the endpoints and the rules it is built to.
