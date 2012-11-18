# This is a base calculator for shipping calculations using the ActiveShipping plugin.
# It is not intended to be instantiated directly. Create subclass for each specific
# shipping method you wish to support instead.
#
# Digest::MD5 is used for cache_key generation.
require 'digest/md5'
require 'iconv' if RUBY_VERSION.to_f < 1.9
require_dependency 'spree/calculator'

module Spree
  class Calculator < ActiveRecord::Base
    module ActiveShipping
      class Base < Calculator
        include ActiveMerchant::Shipping

        def self.service_name
          self.description
        end

        def compute(object)
          order = retrieve_order(object)

          origin = build_location_object
          addr = order.ship_address
          destination = build_location_object(addr)

          order_packages = packages(order) 
          rate_cost = if order_packages.empty?
            {}
          else
            try_cached_rates(order, origin, destination, order_packages)
          end

          unless rate_cost.blank? 
            rate = rate_cost.to_f + (Spree::ActiveShipping::Config[:handling_fee].to_f || 0.0)
            # divide by 100 since active_shipping rates are expressed as cents
            rate / 100.0
          end
        end

        def delivery_date(object)
          order = retrieve_order(object)

          origin = build_location_object
          addr = order.ship_address
          destination = build_location_object(addr)

          order_packages = packages(order) 
          try_cached_rates(order, origin, destination, order_packages, "delivery_date")
        end

        protected
        # weight limit in ounces or zero (if there is no limit)
        def max_weight_for_country(country)
          0
        end

        def retrieve_order(object)
          if object.is_a?(Array)
            object.first.order
          elsif object.is_a?(Shipment)
            object.order
          else
            object
          end
        end

        private
        def retrieve_rates(origin, destination, packages)
          begin
            carrier.find_rates(origin, destination, packages)
          rescue ActiveMerchant::ActiveMerchantError => e

            if [ActiveMerchant::ResponseError, ActiveMerchant::Shipping::ResponseError].include?(e.class) && e.response.is_a?(ActiveMerchant::Shipping::Response)
              params = e.response.params
              if params.has_key?("Response") && params["Response"].has_key?("Error") && params["Response"]["Error"].has_key?("ErrorDescription")
                message = params["Response"]["Error"]["ErrorDescription"]
              # Canada Post specific error message
              elsif params.has_key?("eparcel") && params["eparcel"].has_key?("error") && params["eparcel"]["error"].has_key?("statusMessage")
                message = e.response.params["eparcel"]["error"]["statusMessage"]
              else
                message = e.message
              end
            else
              message = e.message
            end

            error = Spree::ShippingError.new("#{I18n.t(:shipping_error)}: #{message}")
            Rails.cache.write @cache_key, error # write error to cache to prevent constant re-lookups
            raise error
          end
        end

        def try_cached_rates(order, origin, destination, packages, rate_attribute = "price")
          response = Rails.cache.fetch(cache_key(order)) do
            retrieve_rates(origin, destination, packages)
          end

          raise response if response.is_a?(Spree::ShippingError)

          rates = response.rates.collect do |rate|
            # decode html entities for xml-based APIs, ie Canada Post
            if RUBY_VERSION.to_f < 1.9
              service_name = Iconv.iconv('UTF-8//IGNORE', 'UTF-8', rate.service_name).first
            else
              service_name = rate.service_name.encode("UTF-8")
            end
            [CGI.unescapeHTML(service_name), rate.send(rate_attribute)]
          end

          if rates.empty?
            nil
          else
            rates_result = Hash[*rates.flatten]
            rates_result[self.class.description]
          end
        end

        private
        def convert_order_to_weights_array(order)
          multiplier = Spree::ActiveShipping::Config[:unit_multiplier]
          default_weight = Spree::ActiveShipping::Config[:default_weight]
          max_weight = max_weight_for_country(order.ship_address.country)
          
          weights = order.line_items.map do |line_item|
            item_weight = line_item.variant.weight.to_f
            item_weight = default_weight if item_weight <= 0
            item_weight *= multiplier
            
            quantity = line_item.quantity
            if max_weight <= 0
              item_weight * quantity
            else
              if item_weight < max_weight
                max_quantity = (max_weight/item_weight).floor
                if quantity < max_quantity
                  item_weight * quantity
                else
                  new_items = []
                  while quantity > 0 do
                    new_quantity = [max_quantity, quantity].min
                    new_items << (item_weight * new_quantity)
                    quantity -= new_quantity
                  end
                  new_items
                end
              else
                raise Spree::ShippingError.new("#{I18n.t(:shipping_error)}: The maximum per package weight for the selected service from the selected country is #{max_weight} ounces.")
              end
            end
          end
          weights.flatten.sort
        end

        # Generates an array of Package objects based on the quantities and weights of the variants in the line items
        def packages(order)
          units = Spree::ActiveShipping::Config[:units].to_sym
          packages = []
          weights = convert_order_to_weights_array(order)
          max_weight = max_weight_for_country(order.ship_address.country)
          
          if max_weight <= 0
            packages << Package.new(weights.sum, [], :units => units)
          else
            package_weight = 0
            weights.each do |li_weight|
              if package_weight + li_weight <= max_weight
                package_weight += li_weight
              else
                packages << Package.new(package_weight, [], :units => units)
                package_weight = li_weight
              end
            end
            packages << Package.new(package_weight, [], :units => units) if package_weight > 0
          end
          
          packages
        end

        def cache_key(order)
          addr = order.ship_address
          line_items_hash = Digest::MD5.hexdigest(order.line_items.map {|li| li.variant_id.to_s + "_" + li.quantity.to_s }.join("|"))
          @cache_key = "#{carrier.name}-#{order.number}-#{addr.country.iso}-#{addr.state ? addr.state.abbr : addr.state_name}-#{addr.city}-#{addr.zipcode}-#{line_items_hash}-#{I18n.locale}".gsub(" ","")
        end

        def build_location_object(addr = nil)
          if addr
            Location.new(:country => addr.country.iso,
                         :state => (addr.state ? addr.state.abbr : addr.state_name),
                         :city => addr.city,
                         :zip => addr.zipcode)
          else
            Location.new(:country => Spree::ActiveShipping::Config[:origin_country],
                         :city => Spree::ActiveShipping::Config[:origin_city],
                         :state => Spree::ActiveShipping::Config[:origin_state],
                         :zip => Spree::ActiveShipping::Config[:origin_zip])
          end
        end
      end
    end
  end
end
