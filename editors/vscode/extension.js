const vscode = require('vscode');
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

    // eigsdap (#539): the tape debugger — `make dap`, then put eigsdap on
    // PATH. The adapter never executes the program; it steps a recorded
    // trace tape, which is why Step Back / Reverse Continue are enabled.
    context.subscriptions.push(
        vscode.debug.registerDebugAdapterDescriptorFactory('eigenscript-tape', {
            createDebugAdapterDescriptor() {
                return new vscode.DebugAdapterExecutable('eigsdap', []);
            }
        })
    );
}

function deactivate() {
    if (client) return client.stop();
}

module.exports = { activate, deactivate };
