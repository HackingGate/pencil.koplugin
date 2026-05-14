--[[--
Unit tests for annotation grouping and geometry helpers.
Run with: busted spec/annotation_groups_spec.lua
--]]--

-- Add the pencil.koplugin directory to the path so we can require lib/geometry
package.path = package.path .. ";pencil.koplugin/?.lua"

local Geometry = require("lib/geometry")

describe("Geometry", function()

    describe("computeStrokeBbox", function()

        it("returns nil for nil stroke", function()
            assert.is_nil(Geometry.computeStrokeBbox(nil))
        end)

        it("returns nil for stroke with no points", function()
            assert.is_nil(Geometry.computeStrokeBbox({ points = {} }))
        end)

        it("returns nil for stroke with nil points", function()
            assert.is_nil(Geometry.computeStrokeBbox({ points = nil }))
        end)

        it("computes bbox for single point", function()
            local stroke = { points = { { x = 100, y = 200 } } }
            local bbox = Geometry.computeStrokeBbox(stroke)
            assert.equals(100, bbox.x0)
            assert.equals(200, bbox.y0)
            assert.equals(100, bbox.x1)
            assert.equals(200, bbox.y1)
        end)

        it("computes bbox for multiple points", function()
            local stroke = {
                points = {
                    { x = 10, y = 20 },
                    { x = 50, y = 5 },
                    { x = 30, y = 80 },
                },
            }
            local bbox = Geometry.computeStrokeBbox(stroke)
            assert.equals(10, bbox.x0)
            assert.equals(5, bbox.y0)
            assert.equals(50, bbox.x1)
            assert.equals(80, bbox.y1)
        end)

        it("handles points in a horizontal line", function()
            local stroke = {
                points = {
                    { x = 0, y = 100 },
                    { x = 200, y = 100 },
                    { x = 100, y = 100 },
                },
            }
            local bbox = Geometry.computeStrokeBbox(stroke)
            assert.equals(0, bbox.x0)
            assert.equals(100, bbox.y0)
            assert.equals(200, bbox.x1)
            assert.equals(100, bbox.y1)
        end)

    end)

    describe("bboxDistance", function()

        it("returns 0 for overlapping boxes", function()
            local a = { x0 = 0, y0 = 0, x1 = 100, y1 = 100 }
            local b = { x0 = 50, y0 = 50, x1 = 150, y1 = 150 }
            assert.equals(0, Geometry.bboxDistance(a, b))
        end)

        it("returns 0 for contained box", function()
            local a = { x0 = 0, y0 = 0, x1 = 100, y1 = 100 }
            local b = { x0 = 10, y0 = 10, x1 = 50, y1 = 50 }
            assert.equals(0, Geometry.bboxDistance(a, b))
        end)

        it("returns 0 for touching boxes", function()
            local a = { x0 = 0, y0 = 0, x1 = 100, y1 = 100 }
            local b = { x0 = 100, y0 = 0, x1 = 200, y1 = 100 }
            assert.equals(0, Geometry.bboxDistance(a, b))
        end)

        it("returns horizontal gap distance", function()
            local a = { x0 = 0, y0 = 0, x1 = 100, y1 = 100 }
            local b = { x0 = 130, y0 = 0, x1 = 200, y1 = 100 }
            assert.equals(30, Geometry.bboxDistance(a, b))
        end)

        it("returns vertical gap distance", function()
            local a = { x0 = 0, y0 = 0, x1 = 100, y1 = 100 }
            local b = { x0 = 0, y0 = 140, x1 = 100, y1 = 200 }
            assert.equals(40, Geometry.bboxDistance(a, b))
        end)

        it("returns diagonal distance for corner-separated boxes", function()
            local a = { x0 = 0, y0 = 0, x1 = 100, y1 = 100 }
            local b = { x0 = 103, y0 = 104, x1 = 200, y1 = 200 }
            -- dx = 3, dy = 4, distance = 5
            assert.equals(5, Geometry.bboxDistance(a, b))
        end)

        it("is symmetric", function()
            local a = { x0 = 0, y0 = 0, x1 = 50, y1 = 50 }
            local b = { x0 = 100, y0 = 100, x1 = 200, y1 = 200 }
            assert.equals(Geometry.bboxDistance(a, b), Geometry.bboxDistance(b, a))
        end)

    end)

    describe("bboxUnion", function()

        it("computes union of two boxes", function()
            local a = { x0 = 10, y0 = 20, x1 = 50, y1 = 60 }
            local b = { x0 = 30, y0 = 5, x1 = 80, y1 = 40 }
            local u = Geometry.bboxUnion(a, b)
            assert.equals(10, u.x0)
            assert.equals(5, u.y0)
            assert.equals(80, u.x1)
            assert.equals(60, u.y1)
        end)

        it("returns same box when identical", function()
            local a = { x0 = 10, y0 = 20, x1 = 50, y1 = 60 }
            local u = Geometry.bboxUnion(a, a)
            assert.equals(10, u.x0)
            assert.equals(20, u.y0)
            assert.equals(50, u.x1)
            assert.equals(60, u.y1)
        end)

    end)

end)

describe("Annotation grouping logic", function()

    -- Minimal mock of the Pencil object for testing grouping
    local function make_pencil()
        local pencil = {
            strokes = {},
            annotation_groups = {},
            ui = {},  -- no annotation module in tests
        }

        -- Import the grouping functions
        local PencilGeometry = Geometry

        function pencil:assignStrokeToGroup(stroke_idx)
            local stroke = self.strokes[stroke_idx]
            if not stroke then return end
            local bbox = PencilGeometry.computeStrokeBbox(stroke)
            if not bbox then return end
            local stroke_time = stroke.datetime or 0
            local best_group = nil
            for _, group in ipairs(self.annotation_groups) do
                if group.page == stroke.page then
                    local time_diff = math.abs(stroke_time - (group.datetime_last or group.datetime or 0))
                    if time_diff <= 3 then -- GROUP_TIME_THRESHOLD_S
                        local dist = PencilGeometry.bboxDistance(bbox, group.bbox)
                        if dist <= 50 then -- GROUP_SPATIAL_THRESHOLD
                            best_group = group
                            break
                        end
                    end
                end
            end
            if best_group then
                table.insert(best_group.stroke_indices, stroke_idx)
                best_group.bbox = PencilGeometry.bboxUnion(best_group.bbox, bbox)
                best_group.datetime_last = math.max(best_group.datetime_last or 0, stroke_time)
            else
                local group = {
                    id = "pencil_test_" .. stroke_idx,
                    page = stroke.page,
                    stroke_indices = { stroke_idx },
                    bbox = bbox,
                    datetime = stroke_time,
                    datetime_last = stroke_time,
                    tool = stroke.tool or "pen",
                }
                table.insert(self.annotation_groups, group)
            end
        end

        return pencil
    end

    it("creates a new group for the first stroke", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 10, y = 10 }, { x = 20, y = 20 } },
            datetime = 1000,
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        assert.equals(1, #p.annotation_groups)
        assert.equals(1, p.annotation_groups[1].page)
    end)

    it("merges temporally and spatially close strokes", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 10, y = 10 }, { x = 30, y = 10 } },
            datetime = 1000,
            tool = "pen",
        }
        p.strokes[2] = {
            page = 1,
            points = { { x = 35, y = 10 }, { x = 60, y = 10 } },
            datetime = 1002,  -- 2 seconds later (within threshold)
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        p:assignStrokeToGroup(2)
        assert.equals(1, #p.annotation_groups)
        assert.equals(2, #p.annotation_groups[1].stroke_indices)
    end)

    it("separates strokes on different pages", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 10, y = 10 } },
            datetime = 1000,
            tool = "pen",
        }
        p.strokes[2] = {
            page = 2,
            points = { { x = 10, y = 10 } },
            datetime = 1001,
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        p:assignStrokeToGroup(2)
        assert.equals(2, #p.annotation_groups)
    end)

    it("separates strokes with large time gap", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 10, y = 10 }, { x = 30, y = 10 } },
            datetime = 1000,
            tool = "pen",
        }
        p.strokes[2] = {
            page = 1,
            points = { { x = 35, y = 10 }, { x = 60, y = 10 } },
            datetime = 1010,  -- 10 seconds later (beyond threshold)
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        p:assignStrokeToGroup(2)
        assert.equals(2, #p.annotation_groups)
    end)

    it("separates spatially distant strokes even if temporally close", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 10, y = 10 }, { x = 30, y = 10 } },
            datetime = 1000,
            tool = "pen",
        }
        p.strokes[2] = {
            page = 1,
            points = { { x = 500, y = 500 }, { x = 520, y = 500 } },
            datetime = 1001,  -- 1 second later (within threshold)
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        p:assignStrokeToGroup(2)
        assert.equals(2, #p.annotation_groups)
    end)

    it("updates group bbox when merging", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 10, y = 10 }, { x = 30, y = 30 } },
            datetime = 1000,
            tool = "pen",
        }
        p.strokes[2] = {
            page = 1,
            points = { { x = 25, y = 25 }, { x = 60, y = 60 } },
            datetime = 1001,
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        p:assignStrokeToGroup(2)
        assert.equals(1, #p.annotation_groups)
        local bbox = p.annotation_groups[1].bbox
        assert.equals(10, bbox.x0)
        assert.equals(10, bbox.y0)
        assert.equals(60, bbox.x1)
        assert.equals(60, bbox.y1)
    end)

    it("updates datetime_last when merging", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 10, y = 10 } },
            datetime = 1000,
            tool = "pen",
        }
        p.strokes[2] = {
            page = 1,
            points = { { x = 15, y = 15 } },
            datetime = 1002,
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        p:assignStrokeToGroup(2)
        assert.equals(1, #p.annotation_groups)
        assert.equals(1000, p.annotation_groups[1].datetime)
        assert.equals(1002, p.annotation_groups[1].datetime_last)
    end)

    it("handles single-point strokes (dots)", function()
        local p = make_pencil()
        p.strokes[1] = {
            page = 1,
            points = { { x = 100, y = 100 } },
            datetime = 1000,
            tool = "pen",
        }
        p:assignStrokeToGroup(1)
        assert.equals(1, #p.annotation_groups)
        local bbox = p.annotation_groups[1].bbox
        assert.equals(100, bbox.x0)
        assert.equals(100, bbox.y0)
        assert.equals(100, bbox.x1)
        assert.equals(100, bbox.y1)
    end)
end)

describe("Pencil:getGroupColor", function()

    -- Mock of the same getGroupColor logic in main.lua, kept in sync.
    local function make_pencil_with_color()
        local p = { strokes = {} }
        function p:getGroupColor(group)
            if not group or not group.stroke_indices then return nil end
            for _, idx in ipairs(group.stroke_indices) do
                local stroke = self.strokes[idx]
                if stroke and stroke.color then
                    return stroke.color
                end
            end
            return nil
        end
        return p
    end

    it("returns nil for a nil group", function()
        local p = make_pencil_with_color()
        assert.is_nil(p:getGroupColor(nil))
    end)

    it("returns nil for a group with no stroke_indices", function()
        local p = make_pencil_with_color()
        assert.is_nil(p:getGroupColor({}))
    end)

    it("returns the first stroke's color", function()
        local p = make_pencil_with_color()
        p.strokes[1] = { color = "red" }
        p.strokes[2] = { color = "blue" }
        local group = { stroke_indices = { 1, 2 } }
        assert.equals("red", p:getGroupColor(group))
    end)

    it("skips strokes that are missing or have no color", function()
        local p = make_pencil_with_color()
        p.strokes[1] = { color = nil }
        p.strokes[2] = nil
        p.strokes[3] = { color = "green" }
        local group = { stroke_indices = { 1, 2, 3 } }
        assert.equals("green", p:getGroupColor(group))
    end)

    it("returns nil when no stroke in the group has a color", function()
        local p = make_pencil_with_color()
        p.strokes[1] = { color = nil }
        p.strokes[2] = { color = nil }
        local group = { stroke_indices = { 1, 2 } }
        assert.is_nil(p:getGroupColor(group))
    end)

end)
