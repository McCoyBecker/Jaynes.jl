function LinearGaussian(μ::Float64, σ::Float64)
    α = 5.0
    x = rand(:x, Normal(μ, σ))
    y = rand(:y, Normal(α * x, 1.0))
    return y
end

function LinearGaussianProposal()
    α = 10.0
    x = rand(:x, Normal(α * 3.0, 3.0))
end

@testset "Importance sampling" begin
    sel = Jaynes.selection(:x)
    call = Jaynes.trace(LinearGaussian, (0.0, 1.0))
    n_steps = 5

    @testset "Linear Gaussian model" begin
        tr, _ = Jaynes.metropolis_hastings(call, sel)
    end

    @testset "Linear Gaussian proposal" begin
    end
end
