"""
GeometricTrainer: Training with EigenScript's geometric features.

Uses EigenControl for convergence detection, geometric predicates
for adaptive learning, and LRVM embeddings for semantic analysis.
"""

import numpy as np
from typing import List, Dict, Any, Optional, Tuple
from dataclasses import dataclass
from eigenscript.runtime.eigencontrol import EigenControl, EigenControlTracker
from eigenscript.semantic.lrvm import LRVMSpace, LRVMVector


@dataclass
class TrainingState:
    """Captures the geometric state of training."""
    epoch: int
    loss: float
    radius: float
    curvature: float
    framework_strength: float
    conditioning: str
    trend: str
    converged: bool
    improving: bool
    oscillating: bool


class GeometricTrainer:
    """
    Training system using EigenScript's geometric convergence detection.
    
    Key Features:
    - Tracks loss trajectory as geometric radius in LRVM space
    - Uses EigenControl invariant I = ||current - target||² for convergence
    - Provides predicates: converged(), improving(), stable(), oscillating()
    - Adaptive learning rate based on geometric curvature
    """
    
    def __init__(self, target_loss: float = 0.01, dimension: int = 64):
        """
        Initialize geometric trainer.
        
        Args:
            target_loss: Target loss value (convergence goal)
            dimension: Dimension for LRVM space embeddings
        """
        self.target_loss = target_loss
        self.space = LRVMSpace(dimension=dimension)
        self.tracker = EigenControlTracker()
        self.loss_history: List[float] = []
        self.states: List[TrainingState] = []
        
        self.convergence_threshold = 0.95
        self.oscillation_window = 5
        self.oscillation_amplitude_threshold = 0.12
        
        self.current_lr_factor = 1.0
        self.min_lr_factor = 0.1
        self.last_lr_decay_epoch = -10
        self.lr_decay_cooldown = 5
    
    def _embed_loss(self, loss: float) -> LRVMVector:
        """Embed a loss value into LRVM space using proper EigenScript embedding."""
        return self.space.embed_scalar(loss)
    
    def update(self, epoch: int, loss: float) -> TrainingState:
        """
        Update trainer with new loss value and compute geometric state.
        
        Uses EigenScript's EigenControlTracker with proper LRVM embeddings.
        
        Args:
            epoch: Current training epoch
            loss: Current loss value
            
        Returns:
            TrainingState with geometric analysis
        """
        self.loss_history.append(loss)
        
        current_vector = self._embed_loss(loss)
        target_vector = self._embed_loss(self.target_loss)
        
        eigen = self.tracker.update(current_vector, target_vector)
        
        _, trend = self.tracker.get_radius_trend(window=5)
        
        tracker_converged = self.tracker.has_converged(window=3, epsilon=0.01)
        fs_converged = eigen.get_framework_strength() >= self.convergence_threshold
        
        improving = self._compute_improving()
        oscillating = self._compute_oscillating(epoch)
        
        if oscillating and (epoch - self.last_lr_decay_epoch) >= self.lr_decay_cooldown:
            self.current_lr_factor = max(self.min_lr_factor, self.current_lr_factor * 0.7)
            self.last_lr_decay_epoch = epoch
        elif improving and not oscillating:
            self.current_lr_factor = min(1.0, self.current_lr_factor * 1.1)
        
        state = TrainingState(
            epoch=epoch,
            loss=loss,
            radius=eigen.radius,
            curvature=eigen.curvature,
            framework_strength=eigen.get_framework_strength(),
            conditioning=eigen.get_conditioning(),
            trend=trend,
            converged=tracker_converged or fs_converged,
            improving=improving,
            oscillating=oscillating
        )
        
        self.states.append(state)
        return state
    
    def update_from_invariant(self, epoch: int, invariant: float) -> TrainingState:
        """
        Update trainer with a raw Minkowski invariant from geometric loss.
        
        Unlike update() which re-embeds a scalar loss into LRVM space,
        this method takes the invariant I = (h - e)^T g (h - e) directly
        from the geometric loss computation, preserving the native metric
        structure without distortion from embed_scalar().
        
        Framework Strength is computed as FS = 1/(r + 1) where r = sqrt(|I|).
        Convergence occurs when I -> 0 (lightlike equilibrium).
        
        Args:
            epoch: Current training epoch
            invariant: Raw Minkowski invariant value (can be positive or negative)
            
        Returns:
            TrainingState with geometric analysis
        """
        self.loss_history.append(abs(invariant))
        
        invariant_abs = abs(invariant)
        radius = np.sqrt(invariant_abs) if invariant_abs > 0 else 0.0
        curvature = 1.0 / radius if radius > 1e-10 else 1e10
        framework_strength = 1.0 / (radius + 1.0)
        
        _, trend = self.tracker.get_radius_trend(window=5) if len(self.states) >= 5 else (0.0, "initializing")
        
        converged = framework_strength >= self.convergence_threshold
        improving = self._compute_improving()
        oscillating = self._compute_oscillating(epoch)
        
        if oscillating and (epoch - self.last_lr_decay_epoch) >= self.lr_decay_cooldown:
            self.current_lr_factor = max(self.min_lr_factor, self.current_lr_factor * 0.7)
            self.last_lr_decay_epoch = epoch
        elif improving and not oscillating:
            self.current_lr_factor = min(1.0, self.current_lr_factor * 1.1)
        
        state = TrainingState(
            epoch=epoch,
            loss=abs(invariant),
            radius=radius,
            curvature=curvature,
            framework_strength=framework_strength,
            conditioning="well-conditioned" if curvature > 10 else "moderate" if curvature > 1 else "ill-conditioned",
            trend=trend,
            converged=converged,
            improving=improving,
            oscillating=oscillating
        )
        
        self.states.append(state)
        return state
    
    def _compute_improving(self) -> bool:
        """
        Check if loss is decreasing using tracker's radius trend.
        
        Aligned with EigenScript's improving predicate.
        """
        if len(self.tracker.trajectory) < 2:
            return False
        
        _, trend = self.tracker.get_radius_trend(window=5)
        return trend == "contracting"
    
    def _compute_oscillating(self, epoch: int) -> bool:
        """
        Check if training is oscillating using tracker radius trends.
        
        Uses EigenScript's tracker to detect alternating contraction/expansion
        with low net progress (amplitude threshold).
        """
        if len(self.tracker.trajectory) < self.oscillation_window:
            return False
        
        recent = self.tracker.trajectory[-self.oscillation_window:]
        radii = [e.radius for e in recent]
        
        if len(radii) < 3:
            return False
        
        avg_change, trend = self.tracker.get_radius_trend(window=self.oscillation_window)
        
        net_change = abs(radii[-1] - radii[0])
        avg_radius = np.mean(radii)
        
        if avg_radius > 0:
            relative_change = net_change / avg_radius
        else:
            relative_change = 0
        
        deltas = np.diff(radii)
        if len(deltas) >= 2:
            signs = np.sign(deltas)
            sign_changes = np.sum(np.diff(signs) != 0)
            alternation_ratio = sign_changes / (len(deltas) - 1)
        else:
            alternation_ratio = 0
        
        is_oscillating = (
            alternation_ratio > 0.5 and 
            relative_change < self.oscillation_amplitude_threshold and
            trend != "contracting"
        )
        
        return bool(is_oscillating)
    
    def converged(self) -> bool:
        """
        Check if training has converged using geometric criterion.
        
        Convergence occurs when Framework Strength exceeds threshold,
        meaning the radius I = ||current - target||² approaches zero.
        """
        if not self.states:
            return False
        return self.states[-1].converged
    
    def improving(self) -> bool:
        """Check if training is improving (loss decreasing)."""
        if not self.states:
            return False
        return self.states[-1].improving
    
    def stable(self) -> bool:
        """
        Check if training is stable.
        
        Stable = not oscillating and not diverging.
        """
        if not self.states:
            return True
        
        state = self.states[-1]
        return not state.oscillating and state.trend != "expanding"
    
    def oscillating(self) -> bool:
        """Check if training is oscillating."""
        if not self.states:
            return False
        return self.states[-1].oscillating
    
    def diverging(self) -> bool:
        """
        Check if training is diverging (loss increasing).
        
        EigenScript predicate: 'if diverging' - detects negative trajectory.
        """
        if not self.states:
            return False
        return self.states[-1].trend == "expanding"
    
    def equilibrium(self) -> bool:
        """
        Check if training is at equilibrium (balance point).
        
        EigenScript predicate: 'if equilibrium' - zero flow in semantic spacetime.
        Equilibrium means stable, converged, and not oscillating.
        """
        if not self.states:
            return False
        state = self.states[-1]
        return state.converged and not state.oscillating and state.trend == "stable"
    
    def settled(self) -> bool:
        """
        EigenScript humanized alias for 'converged'.
        
        'Has the value settled down?'
        """
        return self.converged()
    
    def balanced(self) -> bool:
        """
        EigenScript humanized alias for 'equilibrium'.
        
        'Is the system in balance?'
        """
        return self.equilibrium()
    
    def stuck(self) -> bool:
        """
        EigenScript humanized predicate: No progress but not done yet.
        
        Stuck means not converged, not improving, but also not diverging.
        """
        if not self.states:
            return False
        state = self.states[-1]
        return not state.converged and not state.improving and not self.diverging()
    
    def chaotic(self) -> bool:
        """
        EigenScript humanized predicate: Unpredictable behavior detected.
        
        Chaotic means oscillating with high amplitude or diverging rapidly.
        """
        if len(self.loss_history) < 5:
            return False
        
        recent = self.loss_history[-5:]
        variance = float(np.var(recent))
        mean_loss = float(np.mean(recent))
        
        if mean_loss > 0:
            coefficient_of_variation = np.sqrt(variance) / mean_loss
            return coefficient_of_variation > 0.5 or self.diverging()
        return self.diverging()
    
    def get_adaptive_lr(self, base_lr: float) -> float:
        """
        Compute adaptive learning rate using compounding adjustments.
        
        Uses:
        - current_lr_factor: Compounds over epochs (reduced when oscillating)
        - Framework Strength: Further reduces LR near convergence
        
        Args:
            base_lr: Base learning rate
            
        Returns:
            Adapted learning rate
        """
        if not self.states:
            return base_lr * self.current_lr_factor
        
        state = self.states[-1]
        
        effective_lr = base_lr * self.current_lr_factor
        
        fs = state.framework_strength
        if fs > 0.9:
            effective_lr *= 0.2
        elif fs > 0.8:
            effective_lr *= 0.4
        elif fs > 0.6:
            effective_lr *= 0.7
        
        return max(effective_lr, base_lr * 0.01)
    
    def get_summary(self) -> Dict[str, Any]:
        """Get summary of training trajectory."""
        if not self.states:
            return {"status": "not_started"}
        
        latest = self.states[-1]
        summary = self.tracker.summary()
        
        return {
            "epochs": len(self.states),
            "current_loss": latest.loss,
            "target_loss": self.target_loss,
            "framework_strength": latest.framework_strength,
            "conditioning": latest.conditioning,
            "trend": latest.trend,
            "converged": latest.converged,
            "improving": latest.improving,
            "oscillating": latest.oscillating,
            "radius": latest.radius,
            "curvature": latest.curvature,
            "eigen_summary": summary
        }
    
    def explain_convergence(self) -> str:
        """
        Provide human-readable explanation of convergence status.
        
        Uses EigenScript's geometric terminology.
        """
        if not self.states:
            return "Training not started."
        
        state = self.states[-1]
        
        lines = [
            f"=== Geometric Training Analysis (Epoch {state.epoch}) ===",
            f"",
            f"Loss: {state.loss:.6f} (target: {self.target_loss:.6f})",
            f"",
            f"Geometric Properties:",
            f"  - Radius (r):     {state.radius:.4e}",
            f"  - Curvature (κ):  {state.curvature:.4e}",
            f"  - Framework Strength: {state.framework_strength:.4f}",
            f"  - Conditioning:   {state.conditioning}",
            f"",
            f"Core Predicates (EigenScript):",
            f"  - converged():   {state.converged}",
            f"  - stable():      {self.stable()}",
            f"  - improving():   {state.improving}",
            f"  - diverging():   {self.diverging()}",
            f"  - oscillating(): {state.oscillating}",
            f"  - equilibrium(): {self.equilibrium()}",
            f"",
            f"Humanized Aliases (EigenScript v0.3.1):",
            f"  - settled():     {self.settled()}",
            f"  - balanced():    {self.balanced()}",
            f"  - stuck():       {self.stuck()}",
            f"  - chaotic():     {self.chaotic()}",
            f"",
            f"Trend: {state.trend}",
        ]
        
        if state.converged:
            lines.append("")
            lines.append(">>> CONVERGED: Training reached geometric equilibrium.")
        elif state.oscillating:
            lines.append("")
            lines.append(">>> OSCILLATING: Consider reducing learning rate.")
        elif not state.improving:
            lines.append("")
            lines.append(">>> PLATEAU: Loss not decreasing. May need architecture changes.")
        
        return "\n".join(lines)
    
    def why_converged(self) -> str:
        """
        Explain WHY training converged (or not) using geometric reasoning.
        
        EigenScript interrogative: 'why converged?'
        """
        if not self.states:
            return "Cannot explain: no training data."
        
        state = self.states[-1]
        
        if state.converged:
            return (
                f"Training converged because Framework Strength ({state.framework_strength:.4f}) "
                f"exceeded threshold ({self.convergence_threshold:.2f}). "
                f"This means the geometric radius I = ||loss - target||² approached zero, "
                f"indicating the model reached the target loss region. "
                f"Curvature κ = {state.curvature:.2e} is very high, showing tight convergence."
            )
        else:
            gap = state.loss - self.target_loss
            return (
                f"Training has NOT converged. Framework Strength is {state.framework_strength:.4f} "
                f"(need {self.convergence_threshold:.2f}). "
                f"Loss gap: {gap:.4f}. Radius: {state.radius:.4e}. "
                f"Trend: {state.trend}. Continue training to reduce the gap."
            )
    
    def how_to_improve(self) -> str:
        """
        Explain HOW to improve training using geometric analysis.
        
        EigenScript interrogative: 'how to improve?'
        """
        if not self.states:
            return "Start training first."
        
        state = self.states[-1]
        suggestions = []
        
        if state.oscillating:
            suggestions.append(
                "OSCILLATING detected: Reduce learning rate by 50% to stabilize. "
                "The loss is bouncing between values, indicating step size is too large."
            )
        
        if state.trend == "expanding":
            suggestions.append(
                "DIVERGING detected: Loss is increasing. Either learning rate is too high, "
                "or gradient explosion is occurring. Try gradient clipping or reduce LR."
            )
        
        if not state.improving and not state.oscillating and state.trend == "stable":
            suggestions.append(
                "PLATEAU detected: Loss not changing. Consider: "
                "(1) Increase model capacity, (2) Add more training data, "
                "(3) Use learning rate warmup or scheduling."
            )
        
        if state.improving and state.conditioning == "ill-conditioned":
            suggestions.append(
                "SLOW PROGRESS: Making progress but problem is ill-conditioned (low curvature). "
                "Training may take many epochs. Consider larger model or better initialization."
            )
        
        if not suggestions:
            if state.converged:
                return "Training has converged successfully. No further action needed."
            else:
                return f"Training progressing normally. Current FS: {state.framework_strength:.4f}. Continue training."
        
        return "\n\n".join(suggestions)


class GeometricEigenTrainer(GeometricTrainer):
    """
    Extended trainer that integrates directly with the transformer model.
    
    Provides the training loop with EigenScript geometric features.
    """
    
    def train_step(
        self,
        model,
        inputs: np.ndarray,
        targets: np.ndarray,
        learning_rate: float,
        epoch: int
    ) -> Tuple[float, TrainingState]:
        """
        Execute one training step with geometric adaptation.
        
        Args:
            model: The transformer model
            inputs: Input sequences
            targets: Target sequences
            learning_rate: Base learning rate
            epoch: Current epoch number
            
        Returns:
            Tuple of (loss, TrainingState)
        """
        from eigenscript.ai.autodiff import Tensor
        
        adapted_lr = self.get_adaptive_lr(learning_rate)
        
        logits = model.forward(inputs)
        loss = model.compute_loss(logits, targets)
        
        loss.backward()
        
        for param in model.parameters():
            if param.grad is not None:
                grad_norm = np.linalg.norm(param.grad)
                if grad_norm > 1.0:
                    param.grad = param.grad * (1.0 / grad_norm)
                param.data -= adapted_lr * param.grad
                param.grad = None
        
        loss_value = float(loss.data)
        
        state = self.update(epoch, loss_value)
        
        return loss_value, state
