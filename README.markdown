About
=====

Erlang-rrdtool is a simple module to allow rrdtool to be treated like an erlang
port via its 'remote control' mode (`rrdtool -`).

You should probably use https://github.com/archaelus/errd instead.

Original version here:
https://github.com/Vagabond/erlang-rrdtool

Usage
=====

Creating a rrd (example #1 from the rrdcreate manpage):

    1> {ok, Pid} = rrdtool:start().
    {ok,<0.221.0>}
    2> rrdtool:create(Pid, "temperature.rrd", [{"temp", 'GAUGE', [600, -273, 5000]}],
        [{'AVERAGE', 0.5, 1, 1200}, {'MIN', 0.5, 12, 2400}, {'MAX', 0.5, 12, 2400},
        {'AVERAGE', 0.5, 12, 2400}]).
    ok

Updating a RRD:

    3> rrdtool:update(Pid, "temperature.rrd", [{"temp", 50}]).
    ok
    4> rrdtool:update(Pid, "temperature.rrd", [{"temp", 75}], now()).
    ok

Updating RRD via rrdcached:

    1> rrdtool:cached_update(Pid,"/var/run/rrdcached.sock","data.rrd",["1"],n).
    {ok,"0 errors, enqueued 1 value(s).\n"}

    2> rrdtool:cached_update(Pid,"/var/run/rrdcached.sock","data.rrd",["1"],now()).
    {ok,"0 errors, enqueued 1 value(s).\n"}

    3> rrdtool:cached_update(Pid,"/var/run/rrdcached.sock","not_found.rrd",["1"],now()).
    {error,"-1 No such file: not_found.rrd\n"}

Fetch data from RRD:

    1> {ok, Pid} = rrdtool:start().
    {ok,<0.41.0>}
    2> rrdtool:fetch(Pid, "data.rrd","MAX","900", "-2h", "-1h").
    {ok, [{"rtt",
      [{"1384235040","2,5905658000e+00"},
        {"1384235160","0,0000000000e+00"},
        {"1384235280","0,0000000000e+00"},
        {"1384235400","0,0000000000e+00"},
        {"1384235520","0,0000000000e+00"},
        {"1384235640","0,0000000000e+00"},
        {"1384235760","0,0000000000e+00"},
        {"1384235880","0,0000000000e+00"},
        {"1384236000","0,0000000000e+00"},
        {"1384236120","0,0000000000e+00"},
        {"1384236240","0,0000000000e+00"},
        {"1384236360","0,0000000000e+00"},
        {"1384236480","0,0000000000e+00"},
        {"1384236600","0,0000000000e+00"},
        {"1384236720","0,0000000000e+00"},
        {"1384236840","3,4217941667e-02"},
        {"1384236960","7,1578736667e-01"},
        {"1384237080","0,0000000000e+00"},
        {"1384237200","0,0000000000e+00"},
        {"1384237320","0,0000000000e+00"},
        {"1384237440","0,0000000000e+00"},
        {"1384237560","0,0000000000e+00"},
        {"1384237680","0,0000000000e+00"},
        {"1384237800",[...]},
        {[...],...},
        {...}|...]}]}

Dependencies:

* procket libarary for unix socket communications


Rebar
=====

To use rrdtool in your projects, add a dependency to your rebar.config:

    {deps, [{rrdtool, ".*",{git, "git://github.com/apofiget/erlang-rrdtool.git"}}]}.
