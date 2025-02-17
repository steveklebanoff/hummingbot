# distutils: language=c++

import pandas as pd
from typing import (
    List,
    Tuple,
)

from hummingbot.market.market_base cimport MarketBase
from hummingbot.core.event.events import (
    TradeType,
    OrderType,
)
from hummingbot.core.data_type.market_order import MarketOrder
from hummingbot.core.data_type.order_book import OrderBook
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.strategy.strategy_base import StrategyBase
from hummingbot.strategy.market_symbol_pair import MarketSymbolPair
from hummingbot.strategy.arbitrage.arbitrage_market_pair import ArbitrageMarketPair
from hummingbot.core.utils.exchange_rate_conversion import ExchangeRateConversion
import logging

NaN = float("nan")
as_logger = None


cdef class ArbitrageStrategy(StrategyBase):
    OPTION_LOG_STATUS_REPORT = 1 << 0
    OPTION_LOG_CREATE_ORDER = 1 << 1
    OPTION_LOG_ORDER_COMPLETED = 1 << 2
    OPTION_LOG_PROFITABILITY_STEP = 1 << 3
    OPTION_LOG_FULL_PROFITABILITY_STEP = 1 << 4
    OPTION_LOG_INSUFFICIENT_ASSET = 1 << 5
    OPTION_LOG_ALL = 0xfffffffffffffff
    MARKET_ORDER_MAX_TRACKING_TIME = 60.0 * 10

    @classmethod
    def logger(cls):
        global as_logger
        if as_logger is None:
            as_logger = logging.getLogger(__name__)
        return as_logger

    def __init__(self,
                 market_pairs: List[ArbitrageMarketPair],
                 min_profitability: float,
                 logging_options: int = OPTION_LOG_ORDER_COMPLETED,
                 status_report_interval: float = 60.0,
                 next_trade_delay_interval: float = 15.0):

        if len(market_pairs) < 0:
            raise ValueError(f"market_pairs must not be empty.")
        super().__init__()
        self._logging_options = logging_options
        self._market_pairs = market_pairs
        self._min_profitability = min_profitability
        self._all_markets_ready = False
        self._status_report_interval = status_report_interval
        self._last_timestamp = 0
        self._next_trade_delay = next_trade_delay_interval
        self._last_trade_timestamps = {}

        cdef:
            set all_markets = {
                market
                for market_pair in self._market_pairs
                for market in [market_pair.first.market, market_pair.second.market]
            }

        self.c_add_markets(list(all_markets))

    @property
    def tracked_taker_orders(self) -> List[Tuple[MarketBase, MarketOrder]]:
        return self._sb_order_tracker.tracked_taker_orders

    @property
    def tracked_taker_orders_data_frame(self) -> List[pd.DataFrame]:
        return self._sb_order_tracker.tracked_taker_orders_data_frame

    def format_status(self) -> str:
        cdef:
            list lines = []
            list warning_lines = []
        for market_pair in self._market_pairs:
            warning_lines.extend(self.network_warning([market_pair.first, market_pair.second]))

            markets_df = self.market_status_data_frame([market_pair.first, market_pair.second])
            lines.extend(["", "  Markets:"] +
                         ["    " + line for line in str(markets_df).split("\n")])

            assets_df = self.wallet_balance_data_frame([market_pair.first, market_pair.second])
            lines.extend(["", "  Assets:"] +
                         ["    " + line for line in str(assets_df).split("\n")])

            profitability_buy_2_sell_1, profitability_buy_1_sell_2 = \
                self.c_calculate_arbitrage_top_order_profitability(market_pair)

            lines.extend(
                ["", "  Profitability:"] +
                [f"    take bid on {market_pair.first.market.name}, "
                 f"take ask on {market_pair.second.market.name}: {round(profitability_buy_2_sell_1 * 100, 4)} %"] +
                [f"    take ask on {market_pair.first.market.name}, "
                 f"take bid on {market_pair.second.market.name}: {round(profitability_buy_1_sell_2 * 100, 4)} %"])

            # See if there're any pending market orders.
            tracked_orders_df = self.tracked_taker_orders_data_frame
            if len(tracked_orders_df) > 0:
                df_lines = str(tracked_orders_df).split("\n")
                lines.extend(["", "  Pending market orders:"] +
                             ["    " + line for line in df_lines])
            else:
                lines.extend(["", "  No pending market orders."])

            warning_lines.extend(self.balance_warning([market_pair.first, market_pair.second]))

        if len(warning_lines) > 0:
            lines.extend(["", "  *** WARNINGS ***"] + warning_lines)

        return "\n".join(lines)

    cdef c_tick(self, double timestamp):
        StrategyBase.c_tick(self, timestamp)

        cdef:
            int64_t current_tick = <int64_t>(timestamp // self._status_report_interval)
            int64_t last_tick = <int64_t>(self._last_timestamp // self._status_report_interval)
            bint should_report_warnings = ((current_tick > last_tick) and
                                           (self._logging_options & self.OPTION_LOG_STATUS_REPORT))
        try:
            if not self._all_markets_ready:
                self._all_markets_ready = all([market.ready for market in self._sb_markets])
                if not self._all_markets_ready:
                    # Markets not ready yet. Don't do anything.
                    if should_report_warnings:
                        self.logger().warning(f"Markets are not ready. No arbitrage trading is permitted.")
                    return
                else:
                    if self.OPTION_LOG_STATUS_REPORT:
                        self.logger().info(f"Markets are ready. Trading started.")

            if not all([market.network_status is NetworkStatus.CONNECTED for market in self._sb_markets]):
                if should_report_warnings:
                    self.logger().warning(f"Markets are not all online. No arbitrage trading is permitted.")
                return

            for market_pair in self._market_pairs:
                self.c_process_market_pair(market_pair)
        finally:
            self._last_timestamp = timestamp

    cdef c_did_complete_buy_order(self, object buy_order_completed_event):
        cdef:
            str order_id = buy_order_completed_event.order_id
            object market_symbol_pair = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
        if market_symbol_pair is not None:
            if self._logging_options & self.OPTION_LOG_ORDER_COMPLETED:
                self.log_with_clock(logging.INFO,
                                    f"Market order completed on {market_symbol_pair[0].name}: {order_id}")

    cdef c_did_complete_sell_order(self, object sell_order_completed_event):
        cdef:
            str order_id = sell_order_completed_event.order_id
            object market_symbol_pair = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
        if market_symbol_pair is not None:
            if self._logging_options & self.OPTION_LOG_ORDER_COMPLETED:
                self.log_with_clock(logging.INFO,
                                    f"Market order completed on {market_symbol_pair[0].name}: {order_id}")

    cdef c_did_fail_order(self, object fail_event):
        cdef:
            str order_id = fail_event.order_id
            object market_symbol_pair = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
        if market_symbol_pair is not None:
            self.log_with_clock(logging.INFO,
                                f"Market order failed on {market_symbol_pair[0].name}: {order_id}")

    cdef c_did_cancel_order(self, object cancel_event):
        cdef:
            str order_id = cancel_event.order_id
            object market_symbol_pair = self._sb_order_tracker.c_get_market_pair_from_order_id(order_id)
        if market_symbol_pair is not None:
            self.log_with_clock(logging.INFO,
                                f"Market order canceled on {market_symbol_pair[0].name}: {order_id}")

    cdef tuple c_calculate_arbitrage_top_order_profitability(self, object market_pair):
        """
        Calculate the profitability of crossing the exchanges in both directions (buy on exchange 2 + sell
        on exchange 1 | buy on exchange 1 + sell on exchange 2) using the best bid and ask price on each.
        :param market_pair:
        :return: (double, double) that indicates profitability of arbitraging on each side
        """
        cdef:
            double market_1_bid_price = ExchangeRateConversion.get_instance().adjust_token_rate(
                market_pair.first.quote_asset, market_pair.first.order_book.get_price(False))
            double market_1_ask_price = ExchangeRateConversion.get_instance().adjust_token_rate(
                market_pair.first.quote_asset, market_pair.first.order_book.get_price(True))
            double market_2_bid_price = ExchangeRateConversion.get_instance().adjust_token_rate(
                market_pair.second.quote_asset, market_pair.second.order_book.get_price(False))
            double market_2_ask_price = ExchangeRateConversion.get_instance().adjust_token_rate(
                market_pair.second.quote_asset, market_pair.second.order_book.get_price(True))
        profitability_buy_2_sell_1 = market_1_bid_price / market_2_ask_price - 1
        profitability_buy_1_sell_2 = market_2_bid_price / market_1_ask_price - 1
        return profitability_buy_2_sell_1, profitability_buy_1_sell_2

    cdef c_ready_for_new_orders(self, list market_symbol_pairs):
        cdef:
            double time_left
            dict tracked_taker_orders = self._sb_order_tracker.c_get_taker_orders()

        for market_symbol_pair in market_symbol_pairs:
            # Do not continue if there are pending market order
            if len(tracked_taker_orders.get(market_symbol_pair, {})) > 0:
                # consider market order completed if it was already x time old
                if any([order.timestamp - self._current_timestamp < self.MARKET_ORDER_MAX_TRACKING_TIME
                       for order in tracked_taker_orders[market_symbol_pair].values()]):
                    return False
            # Wait for the cool off interval before the next trade, so wallet balance is up to date
            ready_to_trade_time = self._last_trade_timestamps.get(market_symbol_pair, 0) + self._next_trade_delay
            if market_symbol_pair in self._last_trade_timestamps and ready_to_trade_time > self._current_timestamp:
                time_left = self._current_timestamp - self._last_trade_timestamps[market_symbol_pair] - self._next_trade_delay
                self.log_with_clock(
                    logging.INFO,
                    f"Cooling off from previous trade on {market_symbol_pair.market.name}. "
                    f"Resuming in {int(time_left)} seconds."
                )
                return False
        return True

    cdef c_process_market_pair(self, object market_pair):
        """
        Check which direction is more profitable (buy/sell on exchange 2/1 or 1/2) and send the more
        profitable direction for execution.
        """
        if not self.c_ready_for_new_orders([market_pair.first, market_pair.second]):
            return

        profitability_buy_2_sell_1, profitability_buy_1_sell_2 = \
            self.c_calculate_arbitrage_top_order_profitability(market_pair)

        if profitability_buy_1_sell_2 < self._min_profitability and profitability_buy_2_sell_1 < self._min_profitability:
            return

        if profitability_buy_1_sell_2 > profitability_buy_2_sell_1:
            # it is more profitable to buy on market_1 and sell on market_2
            self.c_process_market_pair_inner(market_pair.first, market_pair.second)
        else:
            self.c_process_market_pair_inner(market_pair.second, market_pair.first)

    cdef c_process_market_pair_inner(self, object buy_market_symbol_pair, object sell_market_symbol_pair):
        """        
        Execute strategy for the input market pair
        :param buy_market_symbol_pair: MarketSymbolPair
        :param sell_market_symbol_pair: MarketSymbolPair               
        :return: 
        """
        cdef:
            object quantized_buy_amount
            object quantized_sell_amount
            object quantized_order_amount
            double best_amount = 0.0 # best profitable order amount
            double best_profitability = 0.0 # best profitable order amount
            MarketBase buy_market = buy_market_symbol_pair.market
            MarketBase sell_market = sell_market_symbol_pair.market

        best_amount, best_profitability = self.c_find_best_profitable_amount(
            buy_market_symbol_pair, sell_market_symbol_pair
        )
        quantized_buy_amount = buy_market.c_quantize_order_amount(buy_market_symbol_pair.trading_pair, best_amount)
        quantized_sell_amount = sell_market.c_quantize_order_amount(sell_market_symbol_pair.trading_pair, best_amount)
        quantized_order_amount = min(quantized_buy_amount, quantized_sell_amount)

        if quantized_order_amount:
            if self._logging_options & self.OPTION_LOG_CREATE_ORDER:
                self.log_with_clock(logging.INFO,
                                    f"Executing market order buy of {buy_market_symbol_pair.trading_pair} "
                                    f"at {buy_market_symbol_pair.market.name} "
                                    f"and sell of {sell_market_symbol_pair.trading_pair} "
                                    f"at {sell_market_symbol_pair.market.name} "
                                    f"with amount {quantized_order_amount}, "
                                    f"and profitability {best_profitability}")

            self.c_buy_with_specific_market(buy_market_symbol_pair, quantized_order_amount,
                                            order_type=OrderType.MARKET)
            self.c_sell_with_specific_market(sell_market_symbol_pair, quantized_order_amount,
                                             order_type=OrderType.MARKET)
            self._last_trade_timestamps[buy_market_symbol_pair] = self._current_timestamp
            self._last_trade_timestamps[sell_market_symbol_pair] = self._current_timestamp
            self.logger().info(self.format_status())

    @classmethod
    def find_profitable_arbitrage_orders(cls,
                                         min_profitability,
                                         sell_order_book: OrderBook,
                                         buy_order_book: OrderBook,
                                         buy_market_quote_asset,
                                         sell_market_quote_asset):

        return c_find_profitable_arbitrage_orders(min_profitability,
                                                  sell_order_book,
                                                  buy_order_book,
                                                  buy_market_quote_asset,
                                                  sell_market_quote_asset)


    cdef tuple c_find_best_profitable_amount(self, object buy_market_symbol_pair, object sell_market_symbol_pair):
        cdef:
            double total_bid_value = 0 # total revenue
            double total_ask_value = 0 # total cost
            double total_bid_value_adjusted = 0 # total revenue adjusted with exchange rate conversion
            double total_ask_value_adjusted = 0 # total cost adjusted with exchange rate conversion
            double total_previous_step_base_amount = 0
            double profitability
            double best_profitable_order_amount = 0.0
            double best_profitable_order_profitability = 0.0
            object buy_fee
            object sell_fee
            double total_sell_flat_fees
            double total_buy_flat_fees
            double quantized_profitable_base_amount
            double net_sell_proceeds
            double net_buy_costs
            MarketBase buy_market = buy_market_symbol_pair.market
            MarketBase sell_market = sell_market_symbol_pair.market
            OrderBook buy_order_book = buy_market_symbol_pair.order_book
            OrderBook sell_order_book = sell_market_symbol_pair.order_book

        profitable_orders = c_find_profitable_arbitrage_orders(self._min_profitability,
                                                               buy_order_book,
                                                               sell_order_book,
                                                               buy_market_symbol_pair.quote_asset,
                                                               sell_market_symbol_pair.quote_asset)

        # check if each step meets the profit level after fees, and is within the wallet balance
        # fee must be calculated at every step because fee might change a potentially profitable order to unprofitable
        # market.c_get_fee returns a namedtuple with 2 keys "percent" and "flat_fees"
        # "percent" is the percent in decimals the exchange charges for the particular trade
        # "flat_fees" returns list of additional fees ie: [("ETH", 0.01), ("BNB", 2.5)]
        # typically most exchanges will only have 1 flat fee (ie: gas cost of transaction in ETH)
        for bid_price_adjusted, ask_price_adjusted, bid_price, ask_price, amount in profitable_orders:
            buy_fee = buy_market.c_get_fee(
                buy_market_symbol_pair.base_asset,
                buy_market_symbol_pair.quote_asset,
                OrderType.MARKET,
                TradeType.BUY,
                total_previous_step_base_amount + amount,
                ask_price
            )
            sell_fee = sell_market.c_get_fee(
                sell_market_symbol_pair.base_asset,
                sell_market_symbol_pair.quote_asset,
                OrderType.MARKET,
                TradeType.SELL,
                total_previous_step_base_amount + amount,
                bid_price
            )
            # accumulated flat fees of exchange
            total_buy_flat_fees = 0.0
            total_sell_flat_fees = 0.0
            for buy_flat_fee_asset, buy_flat_fee_amount in buy_fee.flat_fees:
                if buy_flat_fee_asset == buy_market_symbol_pair.quote_asset:
                    total_buy_flat_fees += buy_flat_fee_amount
                else:
                    # if the flat fee currency symbol does not match quote symbol, convert to quote currency value
                    total_buy_flat_fees += ExchangeRateConversion.get_instance().convert_token_value(
                        amount=buy_flat_fee_amount,
                        from_currency=buy_flat_fee_asset,
                        to_currency=buy_market_symbol_pair.quote_asset
                    )
            for sell_flat_fee_asset, sell_flat_fee_amount in sell_fee.flat_fees:
                if sell_flat_fee_asset == sell_market_symbol_pair.quote_asset:
                    total_sell_flat_fees += sell_flat_fee_amount
                else:
                    total_sell_flat_fees += ExchangeRateConversion.get_instance().convert_token_value(
                        amount=sell_flat_fee_amount,
                        from_currency=sell_flat_fee_asset,
                        to_currency=sell_market_symbol_pair.quote_asset
                    )
            # accumulated profitability with fees
            total_bid_value_adjusted += bid_price_adjusted * amount
            total_ask_value_adjusted += ask_price_adjusted * amount
            net_sell_proceeds = total_bid_value_adjusted * (1 - sell_fee.percent) - total_sell_flat_fees
            net_buy_costs = total_ask_value_adjusted * (1 + buy_fee.percent) + total_buy_flat_fees
            profitability = net_sell_proceeds / net_buy_costs

            # if current step is within minimum profitability, set to best profitable order
            # because the total amount is greater than the previous step
            if profitability > (1 + self._min_profitability):
                best_profitable_order_amount = total_previous_step_base_amount + amount
                best_profitable_order_profitability = profitability

            if self._logging_options & self.OPTION_LOG_PROFITABILITY_STEP:
                self.log_with_clock(logging.DEBUG, f"Total profitability with fees: {profitability}, "
                                                   f"Current step profitability: {bid_price/ask_price},"
                                                   f"bid, ask price, amount: {bid_price, ask_price, amount}")

            # stop current step if buy/sell market does not have enough asset
            if buy_market_symbol_pair.quote_balance < net_buy_costs or \
                    sell_market_symbol_pair.base_balance < (total_previous_step_base_amount + amount):
                # use previous step as best profitable order if below min profitability
                if profitability < (1 + self._min_profitability):
                    break
                if self._logging_options & self.OPTION_LOG_INSUFFICIENT_ASSET:
                    self.log_with_clock(logging.DEBUG,
                                    f"Not enough asset to complete this step. "
                                    f"Quote asset needed: {total_ask_value + ask_price * amount}. "
                                    f"Quote asset balance: {buy_market_symbol_pair.quote_balance}. "
                                    f"Base asset needed: {total_bid_value + bid_price * amount}. "
                                    f"Base asset balance: {sell_market_symbol_pair.base_balance}. ")

                # market buys need to be adjusted to account for additional fees
                buy_market_adjusted_order_size = (buy_market_symbol_pair.quote_balance / ask_price - total_buy_flat_fees)\
                                                 / (1 + buy_fee.percent)
                # buy and sell with the amount of available base or quote asset, whichever is smaller
                best_profitable_order_amount = min(sell_market_symbol_pair.base_balance, buy_market_adjusted_order_size)
                best_profitable_order_profitability = profitability
                break

            total_bid_value += bid_price * amount
            total_ask_value += ask_price * amount
            total_previous_step_base_amount += amount

        if self._logging_options & self.OPTION_LOG_FULL_PROFITABILITY_STEP:
            self.log_with_clock(logging.DEBUG,
                "\n" + pd.DataFrame(
                    data=[
                        [b_price_adjusted/a_price_adjusted,
                         b_price_adjusted, a_price_adjusted, b_price, a_price, amount]
                        for b_price_adjusted, a_price_adjusted, b_price, a_price, amount in profitable_orders],
                    columns=['raw_profitability', 'bid_price_adjusted', 'ask_price_adjusted',
                             'bid_price', 'ask_price', 'step_amount']
                ).to_string()
            )

        return best_profitable_order_amount, best_profitable_order_profitability

    # The following exposed Python functions are meant for unit tests
    # ---------------------------------------------------------------
    def find_best_profitable_amount(self, buy_market: MarketSymbolPair, sell_market: MarketSymbolPair):
        return self.c_find_best_profitable_amount(buy_market, sell_market)
    def ready_for_new_orders(self, market_pair):
        return self.c_ready_for_new_orders(market_pair)
    # ---------------------------------------------------------------

def find_profitable_arbitrage_orders(min_profitability: float, buy_order_book: OrderBook, sell_order_book: OrderBook,
                                     buy_market_quote_asset: str, sell_market_quote_asset: str):
    return c_find_profitable_arbitrage_orders(min_profitability, buy_order_book, sell_order_book,
                                              buy_market_quote_asset, sell_market_quote_asset)

cdef list c_find_profitable_arbitrage_orders(double min_profitability,
                                             OrderBook buy_order_book,
                                             OrderBook sell_order_book,
                                             str buy_market_quote_asset,
                                             str sell_market_quote_asset):
    """
    Iterates through sell and buy order books and returns a list of matched profitable sell and buy order
    pairs with sizes.
    :param min_profitability: 
    :param buy_order_book: 
    :param sell_order_book: 
    :param buy_market_quote_asset: 
    :param sell_market_quote_asset: 
    :return: ordered list of (bid_price, ask_price, amount) 
    """
    cdef:
        double step_amount = 0
        double bid_leftover_amount = 0
        double ask_leftover_amount = 0
        object current_bid = None
        object current_ask = None
        double current_bid_price_adjusted
        double current_ask_price_adjusted

    profitable_orders = []
    bid_it = sell_order_book.bid_entries()
    ask_it = buy_order_book.ask_entries()
    try:
        while True:
            if bid_leftover_amount == 0 and ask_leftover_amount == 0:
                # both current ask and bid orders are filled, advance to the next bid and ask order
                current_bid = next(bid_it)
                current_ask = next(ask_it)
                ask_leftover_amount = current_ask.amount
                bid_leftover_amount = current_bid.amount

            elif bid_leftover_amount > 0 and ask_leftover_amount == 0:
                # current ask order filled completely, advance to the next ask order
                current_ask = next(ask_it)
                ask_leftover_amount = current_ask.amount

            elif ask_leftover_amount > 0 and bid_leftover_amount == 0:
                # current bid order filled completely, advance to the next bid order
                current_bid = next(bid_it)
                bid_leftover_amount = current_bid.amount

            elif bid_leftover_amount > 0 and ask_leftover_amount > 0:
                # current ask and bid orders are not completely filled, no need to advance iterators
                pass
            else:
                # something went wrong if leftover amount is negative
                break

            # adjust price based on the quote token rates
            current_bid_price_adjusted = ExchangeRateConversion.get_instance().adjust_token_rate(
                sell_market_quote_asset, current_bid.price)
            current_ask_price_adjusted = ExchangeRateConversion.get_instance().adjust_token_rate(
                buy_market_quote_asset,  current_ask.price)
            # arbitrage not possible
            if current_bid_price_adjusted < current_ask_price_adjusted:
                break
            # allow negative profitability for debugging
            if min_profitability<0 and current_bid_price_adjusted/current_ask_price_adjusted < (1 + min_profitability):
                break

            step_amount = min(bid_leftover_amount, ask_leftover_amount)
            profitable_orders.append((current_bid_price_adjusted,
                                      current_ask_price_adjusted,
                                      current_bid.price,
                                      current_ask.price,
                                      step_amount))

            ask_leftover_amount -= step_amount
            bid_leftover_amount -= step_amount

    except StopIteration:
        pass

    return profitable_orders
