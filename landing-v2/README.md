# Landing v2 preview

Status: built for review, not wired to production deployment.

Production on `main` remains unchanged.

## Design

- product-first editorial layout;
- palette: warm paper `#F7F5F0`, ink `#15171A`, Chaptera cobalt `#315EF5`;
- new favicon;
- one dominant `Open PUB` action;
- Windows Reader is secondary;
- Editor / recovery / estate paths move below the fold;
- real-user jobs replace internal status vocabulary in the hero;
- privacy / compatibility / limitations are progressive-disclosure sections.

## Experiment support

The v2 package contains native sticky A/B hero assignment with QA overrides:

- `?variant=A`
- `?variant=B`

Experiments are disabled by default until measurement is configured.

## Cloud Reader safety

Cloud Reader stays fail-closed unless all three are true:

- URL configured;
- availability enabled;
- privacy gate enabled.

## Artifact

Preview ZIP SHA-256:

`d75f7d0a069e9f3382e6663d34ed8b43c7cef886d0fed2ccb9ec2396e77db8d2`

The production artifact and deploy workflow have deliberately not been changed yet.