const fs = require('fs');

const wasmBuffer = fs.readFileSync('examples/playground/orbit.wasm');

const dataPoints = [];

const importObject = {
    env: {
        // WASM-specific print function (non-variadic, direct double value)
        eigen_print_f64: (val) => {
            dataPoints.push(val);
        },
        malloc: (n) => 0,
        free: (p) => {}
    }
};

WebAssembly.instantiate(wasmBuffer, importObject)
    .then(result => {
        console.log('Running main()...');
        const start = Date.now();
        result.instance.exports.main();
        const elapsed = Date.now() - start;
        console.log('Execution time: ' + elapsed + 'ms');
        console.log('Data points generated: ' + dataPoints.length);
        console.log('First 10 values: ' + dataPoints.slice(0, 10).map(v => v.toFixed(3)).join(', '));
        console.log('Last 10 values: ' + dataPoints.slice(-10).map(v => v.toFixed(3)).join(', '));
    })
    .catch(err => console.error('Error:', err));
