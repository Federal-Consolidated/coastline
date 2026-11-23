from coastline_app.core.inventory.items import StockItem, StockShape
from coastline_app.core.plan.stock_orientation import stock_options
from coastline_app.core.units import DisplayUnits


def test_stock_sizes_and_orientation_follow_display_units():
    stock = StockItem.make("al-6061", 25.4, 50.8, 12.7)
    assert stock.size_description_in(DisplayUnits.IMPERIAL) == "1 × 2 × 0.5 in"
    assert stock.size_description == "25.4 × 50.8 × 12.7 mm"
    options = stock_options(stock, [1, 1, 76.2], units=DisplayUnits.IMPERIAL)
    assert any(o.reason == "only 0.5 in deep: the part needs 3" for o in options)
    stock.shape = StockShape.ROUND_BAR
    assert stock.size_description_in(DisplayUnits.IMPERIAL) == "⌀1 × 2 in"
