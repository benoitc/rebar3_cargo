rebar3_monorepo
=====

A rebar plugin

Build
-----

    $ rebar3 compile

Use
---

Add the plugin to your rebar config:

    {plugins, [
        {rebar3_monorepo, {git, "https://host/user/rebar3_monorepo.git", {tag, "0.1.0"}}}
    ]}.

Then just call your plugin directly in an existing application:


    $ rebar3 rebar3_monorepo
    ===> Fetching rebar3_monorepo
    ===> Compiling rebar3_monorepo
    <Plugin Output>
