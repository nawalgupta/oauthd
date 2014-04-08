var express = require("express");

var app = express();
var fs = require('fs');
var config = require('./config');

app.get("/", function(req, res) {
    res.setHeader("Content-Type", "text/html");

    fs.readFile('./index.html', 'UTF-8', function(err, data) {
    	data = data.replace(/{{oauthio_server}}/, config.oauthio_server);
        res.send(data);
    });
});

app.listen(config.port);