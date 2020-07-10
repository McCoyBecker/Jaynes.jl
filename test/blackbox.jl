# Geometric.
geo(p::Float64) = rand(:flip, Bernoulli(p)) ? 0 : 1 + rand(:geo, geo, p)

# Define as primitive.
@primitive function logpdf(fn::typeof(geo), p, count)
    return Distributions.logpdf(Geometric(p), count)
end

@testset "Trace" begin
    ret, cl = trace(geo, 0.5)
    @test haskey(cl.trace, :flip)
end

@testset "Generate" begin
    ret, cl, w = generate(geo, 0.5)
    @test haskey(cl.trace, :flip)
end

@testset "Update" begin
    ret, cl, w = generate(geo, 0.5)
    sel = selection((:flip, true))
    ret, cl, w, retdiff, d = update(sel, cl)
    @test cl[:flip] == true
    ret, cl, w, retdiff, d = update(sel, cl, 0.1)
    @test cl[:flip] == true
end
