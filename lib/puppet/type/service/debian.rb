require 'puppet/type/service/init'

# Manage debian services.  Start/stop is the same as InitSvc, but enable/disable
# is special.
Puppet.type(:service).newsvctype(:debian, :init) do
    # Remove the symlinks
    def disable
        output = %x{update-rc.d -f #{self[:name]} remove 2>&1}

        unless $? == 0
            raise Puppet::Error, "Could not disable %s: %s" %
                [self.name, output]
        end
    end

    def enabled?
        output = %x{update-rc.d -n -f #{self[:name]} remove 2>&1}
        unless $? == 0
            raise Puppet::Error, "Could not check %s: %s" %
                [self.name, output]
        end

        # If it's enabled, then it will print output showing removal of
        # links.
        if output =~ /etc\/rc\d.d/
            return :true
        else
            return :false
        end
    end

    def enable
        output = %x{update-rc.d #{self[:name]} defaults 2>&1}

        unless $? == 0
            raise Puppet::Error, "Could not enable %s: %s" %
                [self.name, output]
        end
    end
end
