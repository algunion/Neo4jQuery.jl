# Round-trip tests for the declared JSON.jl contract of the graph entity types
# (Node/Relationship/Path). These pin the serialized shape so it is intentional
# and stable, not incidental on JSON.jl's default struct reflection.

using Neo4jQuery: Node, Relationship, Path
using JSON
using Test

@testset "Graph entity JSON contract" begin
    @testset "Node" begin
        props = JSON.parse("{\"name\":\"Alice\",\"age\":30}")
        n = Node("4:db:1", ["Person", "Employee"], props)
        parsed = JSON.parse(JSON.json(n))
        @test Set(keys(parsed)) == Set(["element_id", "labels", "properties"])
        @test parsed["element_id"] == "4:db:1"
        @test parsed["labels"] == ["Person", "Employee"]
        @test parsed["properties"]["name"] == "Alice"
        @test parsed["properties"]["age"] == 30
    end

    @testset "Relationship" begin
        rprops = JSON.parse("{\"since\":2020}")
        r = Relationship("5:db:2", "4:db:1", "4:db:3", "KNOWS", rprops)
        parsed = JSON.parse(JSON.json(r))
        @test Set(keys(parsed)) == Set([
            "element_id", "start_node_element_id",
            "end_node_element_id", "type", "properties"])
        @test parsed["element_id"] == "5:db:2"
        @test parsed["start_node_element_id"] == "4:db:1"
        @test parsed["end_node_element_id"] == "4:db:3"
        @test parsed["type"] == "KNOWS"
        @test parsed["properties"]["since"] == 2020
    end

    @testset "Path (nests Node/Relationship contracts)" begin
        n1 = Node("4:db:1", ["Person"], JSON.parse("{\"name\":\"Alice\"}"))
        r = Relationship("5:db:2", "4:db:1", "4:db:3", "KNOWS", JSON.parse("{}"))
        n2 = Node("4:db:3", ["Person"], JSON.parse("{\"name\":\"Bob\"}"))
        p = Path(Union{Node,Relationship}[n1, r, n2])
        parsed = JSON.parse(JSON.json(p))
        @test collect(keys(parsed)) == ["elements"]
        @test length(parsed["elements"]) == 3
        # each element carries its own declared contract
        @test parsed["elements"][1]["element_id"] == "4:db:1"
        @test parsed["elements"][1]["labels"] == ["Person"]
        @test parsed["elements"][2]["type"] == "KNOWS"
        @test parsed["elements"][3]["properties"]["name"] == "Bob"
    end

    @testset "empty containers" begin
        n = Node("4:db:9", String[], JSON.parse("{}"))
        pn = JSON.parse(JSON.json(n))
        @test pn["labels"] == []
        @test pn["properties"] == Dict()

        r = Relationship("5:db:9", "4:db:9", "4:db:10", "REL", JSON.parse("{}"))
        pr = JSON.parse(JSON.json(r))
        @test pr["properties"] == Dict()
        @test pr["type"] == "REL"

        empty_path = Path(Union{Node,Relationship}[])
        pp = JSON.parse(JSON.json(empty_path))
        @test pp["elements"] == []
    end
end
