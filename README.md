rebar3_cargo
=====

A rebar plugin

Build
-----

    $ rebar3 compile

Use
---

Add the plugin to your rebar config:

    {plugins, [
        {rebar3_cargo, {git, "https://host/user/rebar3_cargo.git", {tag, "0.1.0"}}}
    ]}.

Then just call your plugin directly in an existing application:


    $ rebar3 rebar3_cargo
    ===> Fetching rebar3_cargo
    ===> Compiling rebar3_cargo
    <Plugin Output>
