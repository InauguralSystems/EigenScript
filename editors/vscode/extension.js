const { LanguageClient } = require('vscode-languageclient/node');

let client;

function activate(context) {
    const serverOptions = {
        command: 'eigenlsp',
        args: []
    };
    const clientOptions = {
        documentSelector: [{ scheme: 'file', language: 'eigenscript' }]
    };
    client = new LanguageClient(
        'eigenscript',
        'EigenScript Language Server',
        serverOptions,
        clientOptions
    );
    client.start();
}

function deactivate() {
    if (client) return client.stop();
}

module.exports = { activate, deactivate };
