"""
Tests for statistics standard library module.

Tests statistical functions for data analysis and ML workflows.
"""

import pytest
from eigenscript.lexer.tokenizer import Tokenizer
from eigenscript.parser.ast_builder import Parser
from eigenscript.evaluator.interpreter import Interpreter


class TestCentralTendency:
    """Test measures of central tendency."""

    def test_import_statistics_module(self):
        """Test importing the statistics module."""
        source = """
import statistics
data is 10
avg is statistics.mean of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "statistics" in interp.environment.bindings
        assert "avg" in interp.environment.bindings

    def test_mean_function(self):
        """Test mean calculation."""
        source = """
from statistics import mean
data is 100
average is mean of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "mean" in interp.environment.bindings
        assert "average" in interp.environment.bindings

    def test_median_function(self):
        """Test median calculation."""
        source = """
from statistics import median
data is 50
med is median of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "median" in interp.environment.bindings
        assert "med" in interp.environment.bindings

    def test_mode_function(self):
        """Test mode calculation."""
        source = """
from statistics import mode
data is 42
most_common is mode of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "mode" in interp.environment.bindings
        assert "most_common" in interp.environment.bindings


class TestSpreadMeasures:
    """Test measures of spread."""

    def test_variance_function(self):
        """Test variance calculation."""
        source = """
from statistics import variance
data is 50
var is variance of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "variance" in interp.environment.bindings
        assert "var" in interp.environment.bindings

    def test_std_dev_function(self):
        """Test standard deviation calculation."""
        source = """
from statistics import std_dev, std
data is 100
std1 is std_dev of data
std2 is std of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "std_dev" in interp.environment.bindings
        assert "std" in interp.environment.bindings
        assert "std1" in interp.environment.bindings
        assert "std2" in interp.environment.bindings

    def test_range_stat_function(self):
        """Test range calculation."""
        source = """
from statistics import range_stat
data is 75
data_range is range_stat of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "range_stat" in interp.environment.bindings
        assert "data_range" in interp.environment.bindings


class TestQuantiles:
    """Test quantile functions."""

    def test_percentile_function(self):
        """Test percentile calculation."""
        source = """
from statistics import percentile
data is 100
p50 is percentile of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "percentile" in interp.environment.bindings
        assert "p50" in interp.environment.bindings

    def test_quartiles_function(self):
        """Test quartiles calculation."""
        source = """
from statistics import quartiles, iqr
data is 80
q is quartiles of data
interquartile is iqr of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "quartiles" in interp.environment.bindings
        assert "iqr" in interp.environment.bindings
        assert "q" in interp.environment.bindings
        assert "interquartile" in interp.environment.bindings

    def test_quantile_function(self):
        """Test quantile calculation."""
        source = """
from statistics import quantile
data is 90
q_val is quantile of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "quantile" in interp.environment.bindings
        assert "q_val" in interp.environment.bindings


class TestStatisticalMeasures:
    """Test statistical measures."""

    def test_covariance_function(self):
        """Test covariance calculation."""
        source = """
from statistics import covariance
x is 50
cov is covariance of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "covariance" in interp.environment.bindings
        assert "cov" in interp.environment.bindings

    def test_correlation_function(self):
        """Test correlation calculation."""
        source = """
from statistics import correlation
x is 60
corr is correlation of x
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "correlation" in interp.environment.bindings
        assert "corr" in interp.environment.bindings

    def test_z_score_function(self):
        """Test z-score calculation."""
        source = """
from statistics import z_score
value is 75
z is z_score of value
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "z_score" in interp.environment.bindings
        assert "z" in interp.environment.bindings


class TestDistributionProperties:
    """Test distribution property functions."""

    def test_skewness_function(self):
        """Test skewness calculation."""
        source = """
from statistics import skewness
data is 100
skew is skewness of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "skewness" in interp.environment.bindings
        assert "skew" in interp.environment.bindings

    def test_kurtosis_function(self):
        """Test kurtosis calculation."""
        source = """
from statistics import kurtosis
data is 100
kurt is kurtosis of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "kurtosis" in interp.environment.bindings
        assert "kurt" in interp.environment.bindings


class TestNormalization:
    """Test normalization functions."""

    def test_normalize_function(self):
        """Test normalization (min-max scaling)."""
        source = """
from statistics import normalize
data is 150
normalized is normalize of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "normalize" in interp.environment.bindings
        assert "normalized" in interp.environment.bindings

    def test_standardize_function(self):
        """Test standardization (z-score normalization)."""
        source = """
from statistics import standardize
data is 200
standardized is standardize of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "standardize" in interp.environment.bindings
        assert "standardized" in interp.environment.bindings

    def test_rescale_function(self):
        """Test rescaling to custom range."""
        source = """
from statistics import rescale
data is 100
rescaled is rescale of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "rescale" in interp.environment.bindings
        assert "rescaled" in interp.environment.bindings


class TestMovingStatistics:
    """Test moving statistics for time series."""

    def test_moving_average_function(self):
        """Test moving average calculation."""
        source = """
from statistics import moving_average
data is 120
ma is moving_average of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "moving_average" in interp.environment.bindings
        assert "ma" in interp.environment.bindings

    def test_exponential_moving_average_function(self):
        """Test exponential moving average calculation."""
        source = """
from statistics import exponential_moving_average
data is 140
ema is exponential_moving_average of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "exponential_moving_average" in interp.environment.bindings
        assert "ema" in interp.environment.bindings

    def test_rolling_std_function(self):
        """Test rolling standard deviation."""
        source = """
from statistics import rolling_std
data is 110
rolling is rolling_std of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "rolling_std" in interp.environment.bindings
        assert "rolling" in interp.environment.bindings


class TestOutlierDetection:
    """Test outlier detection functions."""

    def test_detect_outliers_function(self):
        """Test outlier detection."""
        source = """
from statistics import detect_outliers
data is 1000
outliers is detect_outliers of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "detect_outliers" in interp.environment.bindings
        assert "outliers" in interp.environment.bindings

    def test_winsorize_function(self):
        """Test winsorization (outlier capping)."""
        source = """
from statistics import winsorize
data is 500
winsorized is winsorize of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "winsorize" in interp.environment.bindings
        assert "winsorized" in interp.environment.bindings


class TestSummaryStatistics:
    """Test summary statistics functions."""

    def test_describe_function(self):
        """Test describe (summary statistics)."""
        source = """
from statistics import describe
data is 175
summary is describe of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "describe" in interp.environment.bindings
        assert "summary" in interp.environment.bindings

    def test_five_number_summary_function(self):
        """Test five number summary."""
        source = """
from statistics import five_number_summary
data is 200
five_num is five_number_summary of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "five_number_summary" in interp.environment.bindings
        assert "five_num" in interp.environment.bindings


class TestCombinedStatistics:
    """Test combining multiple statistical operations."""

    def test_multiple_imports(self):
        """Test importing multiple statistics functions."""
        source = """
from statistics import mean, std_dev, normalize
data is 150
avg is mean of data
std is std_dev of data
norm is normalize of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        assert "mean" in interp.environment.bindings
        assert "std_dev" in interp.environment.bindings
        assert "normalize" in interp.environment.bindings
        assert "avg" in interp.environment.bindings
        assert "std" in interp.environment.bindings
        assert "norm" in interp.environment.bindings

    def test_wildcard_import(self):
        """Test wildcard import of statistics functions."""
        source = """
from statistics import *
data is 100
avg is mean of data
std is std_dev of data
norm is normalize of data
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # Functions should be available directly
        assert "mean" in interp.environment.bindings
        assert "std_dev" in interp.environment.bindings
        assert "normalize" in interp.environment.bindings

    def test_statistics_with_ai_modules(self):
        """Test using statistics with AI/ML modules."""
        source = """
from statistics import normalize, mean
from cnn import batch_norm
from advanced_optimizers import adamw

# Normalize data
data is 250
normalized is normalize of data

# Calculate mean
avg is mean of normalized

# Apply batch norm from CNN
batch_normalized is batch_norm of avg

# Optimize with AdamW
optimized is adamw of batch_normalized
"""
        tokenizer = Tokenizer(source)
        tokens = tokenizer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        interp = Interpreter()
        result = interp.evaluate(ast)

        # All operations should complete
        assert "normalized" in interp.environment.bindings
        assert "avg" in interp.environment.bindings
        assert "batch_normalized" in interp.environment.bindings
        assert "optimized" in interp.environment.bindings
