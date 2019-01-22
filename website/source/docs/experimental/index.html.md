---
layout: "docs"
page_title: "Vagrant Experimental Feature Flag"
sidebar_current: "experimental"
description: |-
  Introduction to Vagrants Experimental Feature Flag
---

# Experimental Feature Flag

Some features that aren't ready for release can be enabled through this feature
flag. There are a couple of different ways of going about enabling these features:

If you wish to enale every single experimental feature, you can set the flag
to "on" by setting it to `1` like below:

```shell
export VAGRANT_EXPERIMENTAL="1"
```

You can also enable some or many features if there are specific ones you would like,
but don't want every single feature enabled:

```shell
# Only enables feature_one
export VAGRANT_EXPERIMENTAL="feature_one"
```

```shell
# Enables both feature_one and feature_two
export VAGRANT_EXPERIMENTAL="feature_one,feature_two"
```

<div class="alert alert-warning">
  <strong>Advanced topic!</strong> This is an advanced topic for use only if
  you want to use new Vagrant features.. If you are just getting
  started with Vagrant, you may safely skip this section.

  It is also worth noting that Vagrant will not validate the existance of a
  feature flag.
</div>

## Valid experimental features

This is a list of all the valid experimental features that Vagrant recognizes:

### `typed_triggers`

Enabling this feature allows triggers to recognize and execute `:type` triggers.
More information about how these should be used can be found on the [trigger documentation page](/docs/triggers/configuration.html#trigger-types)