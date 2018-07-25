local helpers = require "spec.helpers"


local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"


for _, strategy in helpers.each_strategy() do
  describe("kong.db [#" .. strategy .. "]", function()
    local db, bp

    setup(function()
      bp, db = helpers.get_db_utils(strategy)
    end)

    describe("Plugins #plugins", function()
      describe(":insert()", function()
        it("created_at/updated_at cannot be overriden", function()
          local route = bp.routes:insert({ methods = {"GET"} })

          local plugin, err, err_t = db.plugins:insert({
            name = "datadog",
            route = { id = route.id },
          })
          assert.is_nil(err_t)
          assert.is_nil(err)

          assert.matches(UUID_PATTERN, plugin.id)
          assert.is_number(plugin.created_at)
          plugin.id = nil
          plugin.created_at = nil

          assert.same({
            api = ngx.null,
            config = ngx.null,
            consumer = ngx.null,
            enabled = true,
            name = "datadog",
            route = {
              id = route.id,
            },
            service = ngx.null,
          }, plugin)

          plugin, err, err_t = db.plugins:insert({
            name = "datadog",
            route = route,
          })

          assert.falsy(plugin)
          assert.match("UNIQUE violation", err)
          assert.same("unique constraint violation", err_t.name)
          assert.same([[UNIQUE violation detected on '{consumer=null,]] ..
                      [[api=null,service=null,name="datadog",route={id="]] ..
                      route.id .. [["}}']], err_t.message)
        end)
      end)
    end)

  end) -- kong.db [strategy]
end
