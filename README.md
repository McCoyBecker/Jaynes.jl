<i><h1 style="color: purple">Jaynes</h1></i>


<p align="center">
<img width="200px" src="img/jaynes.jpeg"/>
</p>
<br>

Heavily inspired by <a href="https://probcomp.github.io/Gen/">Gen.jl</a> and <a href="https://github.com/MikeInnes/Poirot.jl">Poirot.jl</a>: <i><span style="color: purple">Jaynes</span></i> is a minimal trace-based PPL but includes the usage of IR manipulations for non-standard interpretation and analysis, which may help by providing information which can be used during inference programming.

This might allow us to do cool things like:
1. Grab the dependency graph of a probabilistic program as a static pass and analyze it!
2. Possibly store analysis meta-data for inference programming (i.e. sub-graphs with exponential conjugacy can be identified).
3. Belief propagation and trace-based inference in one PPL like whaaaaaaaaaa

Work in progress :)
